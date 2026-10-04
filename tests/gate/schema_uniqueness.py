#!/usr/bin/env python3
"""Prove that two matrix jobs in one workflow run cannot be handed the same schema.

Reads the real ``integration`` job out of the workflow file, substitutes the GitHub
context exactly the way Actions would, then composes ``MC_SCHEMA_MC_RUN_ID`` the way
``scripts/run-maxcompute-integration-tests.sh`` does and checks the results are pairwise
distinct. Every job is simulated as starting in the *same* second, because second
resolution is precisely what used to be the only difference between two suites.

Usage:
    python3 tests/gate/schema_uniqueness.py [.github/workflows/maxcompute-integration.yml]

Exit codes: 0 no collision | 1 a collision or an unusable name was produced | 2 the
workflow does not have the shape this test expects.
"""
import os
import re
import subprocess
import sys

SUITES = ["integration_tests", "integration_tests_2", "integration_tests_minimal",
          "integration_tests_empty"]

# run id, run attempt, run number. Two jobs from the same run share the first and third;
# a re-run of a workflow shares run_id but bumps run_attempt.
RUNS = [("12345678", "1", "900"), ("12345678", "2", "900"), ("87654321", "1", "901")]


def render(expression, suite, run_id, attempt, run_number):
    """Substitute the ``${{ ... }}`` expressions Actions exposes to a matrix job."""
    values = {
        "github.run_id": run_id,
        "github.run_attempt": attempt,
        "github.run_number": run_number,
        "github.job": "integration",
        "matrix.suite": suite,
        "strategy.job-index": str(SUITES.index(suite)),
    }

    def replace(match):
        key = match.group(1).strip()
        if key not in values:
            raise KeyError(key)
        return values[key]

    return re.sub(r"\$\{\{([^}]*)\}\}", replace, expression)


def job_env(workflow_path):
    """Pull MC_SCHEMA / MC_RUN_ID out of the integration job without needing PyYAML."""
    with open(workflow_path) as handle:
        lines = handle.read().splitlines()
    try:
        start = next(i for i, line in enumerate(lines)
                     if re.match(r"^    integration:\s*$", line))
    except StopIteration:
        print("SCHEMA-TEST: FAIL no `integration:` job in %s" % workflow_path)
        sys.exit(2)
    # `env:` under a matrix job is nested one level deeper than a job-level env, so the
    # indent is matched from the file rather than hard-coded.
    env = {}
    env_indent = None
    for line in lines[start:]:
        if env_indent is None:
            if re.match(r"^    [a-zA-Z_-]+:\s*$", line) and not line.startswith("    integration:"):
                break
            match = re.match(r"^( +)env:\s*$", line)
            if match:
                env_indent = len(match.group(1))
            continue
        if not line.strip():
            continue
        if len(line) - len(line.lstrip()) <= env_indent:
            break
        match = re.match(r"^( +)([A-Z_][A-Z0-9_]*): (.*)$", line)
        if match and len(match.group(1)) == env_indent + 4:
            env[match.group(2)] = match.group(3).strip()
    missing = [key for key in ("MC_SCHEMA", "MC_RUN_ID") if key not in env]
    if missing:
        print("SCHEMA-TEST: FAIL the integration job does not set %s (MC_RUN_ID is the "
              "field that used to fall back to a UTC second)" % ", ".join(missing))
        sys.exit(2)
    return env


def main(argv):
    path = argv[0] if argv else ".github/workflows/maxcompute-integration.yml"
    if not os.path.exists(path):
        print("SCHEMA-TEST: FAIL %s does not exist" % path)
        return 2
    env = job_env(path)
    print("SCHEMA-TEST: reading %s" % path)
    print("  MC_SCHEMA = %s" % env["MC_SCHEMA"])
    print("  MC_RUN_ID = %s" % env["MC_RUN_ID"])

    composed = {}
    problems = []
    for suite in SUITES:
        for run_id, attempt, run_number in RUNS:
            schema = render(env["MC_SCHEMA"], suite, run_id, attempt, run_number)
            run_id_token = render(env["MC_RUN_ID"], suite, run_id, attempt, run_number)
            # this is exactly the composition in the entrypoint
            name = "%s_%s" % (schema, run_id_token)
            composed[(suite, run_id, attempt)] = name
            if not re.match(r"^[A-Za-z][A-Za-z0-9_]*$", name):
                problems.append("%s: '%s' is not a plain identifier" % (suite, name))
            if len(name) > 64:
                problems.append("%s: '%s' is %d characters (>64)" % (suite, name, len(name)))

    for key in sorted(composed):
        print("  job suite=%-25s run_id=%s attempt=%s -> %s" % (key[0], key[1], key[2], composed[key]))

    # one run, same second, several suites: the case the review pointed at
    per_run = {}
    for (suite, run_id, attempt), name in composed.items():
        per_run.setdefault((run_id, attempt), {})[suite] = name
    collisions = []
    for (run_id, attempt), names in per_run.items():
        seen = {}
        for suite, name in names.items():
            seen.setdefault(name, []).append(suite)
        for name, users in seen.items():
            if len(users) > 1:
                collisions.append("run %s attempt %s: suites %s would share schema '%s'"
                                  % (run_id, attempt, ", ".join(sorted(users)), name))

    # a re-run of the same run must not reuse a schema either
    for suite in SUITES:
        a = composed.get((suite, "12345678", "1"))
        b = composed.get((suite, "12345678", "2"))
        if a and b and a == b:
            collisions.append("suite %s reuses schema '%s' across run attempts" % (suite, a))

    if collisions:
        for line in collisions:
            print("SCHEMA-TEST: COLLISION %s" % line)
    for line in problems:
        print("SCHEMA-TEST: BADNAME %s" % line)

    if collisions or problems:
        print("SCHEMA-TEST: FAIL collisions=%d bad_names=%d" % (len(collisions), len(problems)))
        return 1
    print("SCHEMA-TEST: OK %d job shapes, all schemas distinct per run and attempt, "
          "all plain identifiers <= 64 characters" % len(composed))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
