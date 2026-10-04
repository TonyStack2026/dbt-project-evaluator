#!/usr/bin/env python3
"""Support helpers for the MaxCompute integration suites.

Subcommands
  preflight  -- is the configured project reachable and usable by dbt (three-tier)?
                then make sure this run's schema exists.
  summary    -- turn a dbt run_results.json into one machine-readable line.
  cleanup    -- drop the schemas this run created, and prove they are gone.

Credentials are read from the environment by the caller (the adapter's
``auth_type: chain`` uses the same variables). Nothing here prints a secret.
"""
import json
import os
import sys
import time


def _client():
    # Imported here rather than at module scope: `summary` reads a file that dbt
    # already wrote, so it must stay runnable (and testable) on a machine that has
    # no pyodps installed - which is the case on a fork PR's runner.
    from odps import ODPS

    return ODPS(
        os.environ["ODPS_ACCESS_ID"],
        os.environ["ODPS_ACCESS_KEY"],
        project=os.environ["MC_PROJECT"],
        endpoint=os.environ["MC_ENDPOINT"],
    )


def _host():
    return os.environ.get("MC_ENDPOINT", "").split("://")[-1].split("/")[0]


def _schemas(odps_client):
    return {s.name for s in odps_client.list_schemas()}


def preflight(schema):
    """Prove the project is reachable and schema-capable before any dbt run.

    A two-tier project fails on list_schemas, which is exactly the condition
    dbt hits later as a confusing ODPS-0110061, so it is reported here instead.
    ``schema_created_by_this_run`` decides what cleanup is allowed to delete.
    """
    odps_client = _client()
    try:
        existing = _schemas(odps_client)
    except Exception as exc:  # two-tier projects fail here
        print("PREFLIGHT: FAIL project %s is not usable with a dbt three-tier "
              "profile: %s: %s" % (os.environ["MC_PROJECT"],
                                   type(exc).__name__, exc))
        return 2
    created = False
    if schema not in existing:
        try:
            odps_client.create_schema(schema)
        except Exception as exc:
            print("PREFLIGHT: FAIL cannot create schema %s: %s: %s"
                  % (schema, type(exc).__name__, exc))
            return 2
        created = True
    print("PREFLIGHT: OK project=%s endpoint_host=%s schemas=%d schema=%s "
          "schema_created_by_this_run=%s"
          % (os.environ["MC_PROJECT"], _host(), len(existing) + int(created),
             schema, str(created).lower()))
    return 0


# Statuses that mean "this node reached the warehouse and produced an outcome".
# dbt-core 1.11 writes ``success`` for a model, ``pass`` for a test, ``warn`` for an
# executed node that warned, ``no-op`` (with the hyphen - measured on the real
# run_results.json of a live 155-node run, where one exposure reported it) for a node it
# decided not to run, ``skipped`` for a node whose dependencies failed, and ``error`` /
# ``fail`` for the two ways a node says no. Compared after normalisation, because the
# spellings carry hyphens and spaces.
EXECUTED_OK = frozenset(("success", "pass", "warn"))
EXECUTED_BAD = frozenset(("error", "fail", "runtime_error", "partial_success"))
DID_NOT_EXECUTE = frozenset(("skipped", "no_op"))


def normalise(status):
    return str(status).strip().lower().replace("-", "_").replace(" ", "_")

# A suite is only evidence if at least this many nodes actually ran. It exists to
# catch "dbt parsed the project and did nothing", not to assert a node count: the
# measured suites run 50-155 nodes, so 1 is a deliberately weak floor. Every node
# a suite skips has to be visible in the line, or a green gate means nothing.
MIN_EXECUTED = 1


def summary(path, label):
    """Turn one dbt run_results.json into a gate decision.

    Three shapes are failures in their own right, because each of them used to be
    reported as a pass: no results at all, every result skipped, and any node that
    errored or failed. The exit code, not the prose, is what CI judges.
    """
    if not os.path.exists(path):
        print("SUITE %s: NO-RESULTS (dbt did not write run_results.json)" % label)
        return 1
    try:
        with open(path) as handle:
            data = json.load(handle)
    except ValueError as exc:
        print("SUITE %s: BAD-RESULTS (run_results.json is not JSON: %s)" % (label, exc))
        return 1
    results = data.get("results")
    if results is None:
        print("SUITE %s: NO-RESULTS (run_results.json has no 'results' key)" % label)
        return 1
    if not isinstance(results, list):
        print("SUITE %s: BAD-RESULTS ('results' is %s, expected a list)"
              % (label, type(results).__name__))
        return 1

    counts = {}
    failures = []
    for result in results:
        status = normalise(result.get("status"))
        counts[status] = counts.get(status, 0) + 1
        if status in EXECUTED_BAD or status not in EXECUTED_OK | DID_NOT_EXECUTE:
            failures.append((result.get("unique_id"),
                             (result.get("message") or "").splitlines()[:1]))

    executed = sum(counts.get(status, 0) for status in EXECUTED_OK | EXECUTED_BAD)
    skipped = sum(counts.get(status, 0) for status in DID_NOT_EXECUTE)
    total = sum(counts.values())

    line = "SUITE %s: TOTAL=%d EXECUTED=%d SKIPPED=%d" % (label, total, executed, skipped)
    for status, count in sorted(counts.items()):
        line += " %s=%d" % (status.replace(" ", "_").upper(), count)
    print(line)
    for unique_id, message in failures[:20]:
        print("  NOT-PASS %s: %s" % (unique_id, message))
    if len(failures) > 20:
        print("  NOT-PASS ... %d more" % (len(failures) - 20))

    if total == 0:
        print("SUITE %s: GATE=FAIL no node produced a result (an empty suite is not a pass)"
              % label)
        return 1
    if failures:
        print("SUITE %s: GATE=FAIL %d node(s) errored, failed or reported an unknown status"
              % (label, len(failures)))
        return 1
    if executed < MIN_EXECUTED:
        print("SUITE %s: GATE=FAIL every node was skipped/no-op (%d of %d), so no rule was "
              "actually evaluated" % (label, skipped, total))
        return 1
    print("SUITE %s: GATE=PASS %d node(s) executed, %d skipped, 0 failed"
          % (label, executed, skipped))
    return 0


def _drop_relations(odps_client, schema):
    """A schema can only be dropped once it is empty, and dbt leaves tables and
    views behind in it, so relations go first."""
    dropped = 0
    for relation in list(odps_client.list_tables(schema=schema)):
        try:
            odps_client.delete_table(relation.name, schema=schema, if_exists=True)
            dropped += 1
        except Exception as exc:
            print("CLEANUP: FAIL cannot drop %s.%s: %s: %s"
                  % (schema, relation.name, type(exc).__name__, exc))
    return dropped


def cleanup(schemas):
    """Delete only the schemas this run reported as its own, then re-read the
    project to prove none of them survived."""
    odps_client = _client()
    for schema in schemas:
        try:
            if odps_client.exist_schema(schema):
                relations = _drop_relations(odps_client, schema)
                odps_client.delete_schema(schema)
                print("CLEANUP: dropped schema %s with %d relation(s) inside"
                      % (schema, relations))
        except Exception as exc:
            print("CLEANUP: FAIL cannot drop %s: %s: %s"
                  % (schema, type(exc).__name__, exc))
    # 删除与元数据可见之间可能有短暂滞后（实测：drop 已成功，立刻回读仍报存在），
    # 所以按"最多等 60 秒"复查；仍然存在的才是真泄漏。
    pending = list(schemas)
    for _ in range(12):
        pending = [s for s in pending if odps_client.exist_schema(s)]
        if not pending:
            break
        time.sleep(5)
    if pending:
        print("CLEANUP: FAIL schemas still present: %s" % pending)
        return 1
    print("CLEANUP: OK dropped %d schema(s) owned by this run: %s"
          % (len(schemas), ", ".join(schemas) if schemas else "none"))
    return 0


def main(argv):
    if not argv:
        print(__doc__)
        return 2
    command = argv[0]
    if command == "preflight":
        return preflight(argv[1])
    if command == "summary":
        return summary(argv[1], argv[2])
    if command == "cleanup":
        return cleanup(argv[1:])
    print("unknown command: %s" % command)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
