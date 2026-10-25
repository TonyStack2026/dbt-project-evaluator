# MaxCompute integration tests

MaxCompute support used to be documented as "tested manually", which means nobody could
re-run the check and a broken install looked the same as a passing one. These suites replace
that: one entrypoint, three fixture projects, and a run that says out loud when it never
reached a warehouse.

## What runs

| Suite | What it is | What it proves |
| --- | --- | --- |
| `integration_tests_minimal` | a fixed minimal DAG: a healthy base → staging → intermediate → marts chain over a real seed, plus one model per deliberate violation (root model, unused source, direct join to a source, missing prefix, missing description, hard coded reference) | the rules fire on the resources they are supposed to fire on, the healthy chain is *not* reported, and the exemptions seed stops a reported row from coming back |
| `integration_tests_empty` | a project with no models, seeds, sources or exposures | an empty project builds and every pinned rule returns zero findings instead of inventing rows or failing on a missing denominator |
| ↳ 上一行的边界（10-25 实测补充） | 「empty」指**没有 findings**，不是没有关系 | `dbt build` 在这里仍会落 49 个关系（`MATERIALIZING=49`，own schema `relations=49`，2026-10-25 真机），因为它照样构建包自身的模型；别把这一套当成 `RUN-SCHEMA: SKIPPED` 的例子 |
| `integration_tests` | the upstream fixture project (its own seeds hold the expected output of each rule model) | rule-by-rule equality against expected rows on MaxCompute |

Expectations are expressed as SQL tests that run against the package's own `fct_*` /
`int_*` relations, so a green suite means the warehouse produced those rows — not that a
parser accepted some YAML.

## Running it locally

```bash
export MC_PROJECT=<your three-tier MaxCompute project>
export MC_ENDPOINT=<your endpoint>
export MC_SCHEMA=dpe_it                    # optional, default dbt_project_evaluator_it
./scripts/run-maxcompute-integration-tests.sh            # all suites
./scripts/run-maxcompute-integration-tests.sh integration_tests_minimal
```

`ODPS_ACCESS_ID` / `ODPS_ACCESS_KEY` (or `ALIBABA_CLOUD_ACCESS_KEY_ID` / `_SECRET`) are read
from the environment and passed to the adapter through `auth_type: chain`. The generated
`profiles.yml` lives in a temp directory that is deleted on exit, contains no secret
material, and is never written into the repository.

Options and extras:

- `MC_RUN_ID` — suffix for this run's schema (default: UTC timestamp plus the process id).
  A run owns `MC_SCHEMA_MC_RUN_ID`, and the composed name has to be one plain identifier
  (`[A-Za-z0-9_]`, at most 64 characters) or the run stops with `INTEGRATION: BLOCKED`.
  A second-resolution timestamp alone is **not** enough to isolate concurrent runs, which is
  why the CI matrix puts the suite name in `MC_SCHEMA` and `run_id` + `run_attempt` in
  `MC_RUN_ID` instead of relying on the default; see *Isolation* below.
- `MC_KEEP_SCHEMAS=1` — leave the run's schema in place for inspection.
- `DPE_ARTIFACT_DIR` — copy each `run_results.json` here.
- `DPE_DBT_EXTRA` — extra dbt build flags, e.g. `--select tag:my_subset`.

## What makes a suite count as passed

All five conditions, per suite:

1. `dbt build` exited 0;
2. `target/run_results.json` exists **and belongs to this invocation** - the entrypoint
   removes a previous run's file before building, because dbt writes it only at the end of a
   run, so an interrupted or timed-out build otherwise leaves the last completed run's file
   sitting in `target/` for the gate to read;
3. it lists at least one node that actually executed (`success` / `pass` / `warn`);
4. no node errored, failed, or reported a status this file does not know;
5. if any node that executed is supposed to leave a relation behind (a model, seed or
   snapshot), the schema this run owns actually holds at least one relation. That is read
   from the project, before cleanup, rather than inferred from what dbt said it did.

So these are **failures**, each of them used to be a pass:

| Shape | Reported as | Why it matters |
| --- | --- | --- |
| `run_results.json` with `results: []` | `GATE=FAIL no node produced a result` | a project that parsed and built nothing evaluates no rule |
| every node `skipped` / `noop` | `GATE=FAIL every node was skipped/no-op` | a suite that skipped itself looks identical to a green one from the exit code alone |
| `dbt build` exits non-zero with a clean-looking results file | `SUITE <name>: BUILD-FAILED` | an interrupted or aborted run is dbt saying no, whatever it wrote first |
| a requested suite directory has no `dbt_project.yml` | `SUITE <name>: NOT-PRESENT ... counted as a failure` | renaming or deleting a suite must cost coverage loudly, not quietly |
| no suite ran at all | `INTEGRATION: FAIL - no suite ran` | the loop finishing is not the same as the loop having work |
| `MC_SCHEMA_MC_RUN_ID` is not one plain identifier, or is longer than 64 characters | `INTEGRATION: BLOCKED` | a name with a separator is the same name on a server that folds identifiers, so two suites would share a schema |
| `dbt` was interrupted or timed out and wrote no results, so the only file in `target/` is a previous invocation's | `SUITE <name>: NOT-RUN (dbt wrote no run_results.json)`, preceded by `SUITE <name>: stale run_results.json from a previous invocation removed before building` | a stale file describes somebody else's run. Crediting it prints `GATE=PASS` for work that never happened - measured on a build killed by the timeout, whose results file still carried an invocation 11 days older |
| model/seed/snapshot nodes report executed while the run's own schema holds 0 relations | `RUN-SCHEMA: EMPTY ... (not a pass)` | results only prove dbt *reported* success. If the relations landed in some other schema - a resolved-schema regression, a `database`/`schema` override in the fixtures - the isolation above is defeated and cleanup still says OK, because dropping an empty schema is trivially green |
| the run's own schema is gone or cannot be read at that moment | `RUN-SCHEMA: MISSING` + `RUN-SCHEMA: UNREADABLE (rc=...)` | a failed read must not be reported as the very finding this check looks for, nor defaulted to "empty": it is its own failure |

The line each suite prints carries the counts, so a green run is auditable rather than
trusted: `SUITE <name>: MATERIALIZING=m ...` (relation-bearing nodes that executed) followed by
`SUITE <name>: TOTAL=n EXECUTED=k SKIPPED=s ... GATE=PASS k node(s) executed`, and the run ends
with `RUN-SCHEMA: schema=<name> relations=r`.

Two boundaries of rule 5, stated because they are easy to over-read:

- it is per invocation, and one invocation shares a single schema across the suites it runs.
  The CI matrix gives one suite per job, so in CI it is exactly per suite;
- it proves *something* landed in the schema the run owns, not that every relation did. A
  partial mis-landing still needs the per-model catalog, which is what `docs generate`
  evidence covers, not this gate.

Because "a gate that cannot go red" is the failure mode this whole entrypoint exists to
avoid, the rules above are themselves tested: `./scripts/test-mc-integration-gate.sh` runs
one case per shape against the real scripts, on a machine with no credentials, no warehouse
and no pyodps, and it also reads the workflow file to check that the schemas a matrix would
compose are pairwise distinct. It runs in CI as `gate-selftest`, on every pull request.
The warehouse is doubled (`tests/gate/fake_odps.py`), every suite directory in the harness
starts with a previous invocation's `run_results.json` in place (a decoy - a gate that reads the
file without clearing it will credit it), and the fake `dbt` writes relations into
the schema it is handed, so a case can distinguish "the results file claims models ran" from
"the schema actually has relations" - the pair `executed_no_relations` (must go red) and
`tests_only` (must stay green with an empty schema) is what keeps that rule from being a
guess or from false-alarming on a suite that has nothing to materialise.

Exit codes:

| Code | Meaning |
| --- | --- |
| 0 | every suite ran against the project and passed |
| 1 | a suite failed, produced no executed result, was requested but absent, `dbt` exited non-zero, or the run schema was empty / unreadable while relation-bearing nodes reported executed |
| 2 | **blocked**: no credentials, no `MC_PROJECT`/`MC_ENDPOINT`, the project is unreachable, it is a two-tier project, or the run schema is not one safe identifier. No SQL ran, so this is not a pass. |

A blocked run is reported as `INTEGRATION: BLOCKED - <reason>`; a suite whose packages could
not be installed is reported as `SUITE <name>: NOT-RUN`. Both are distinct from "0 nodes
failed", which is what a passing run says.

Cleanup is ownership-based: the entrypoint records whether *this* run created the schema and
only drops what it created, then re-reads the project to prove nothing survived. A schema that
already existed is left alone, because another run may be using it.

## Isolation between concurrent runs

Each run owns `MC_SCHEMA_MC_RUN_ID`. In the CI matrix that is composed as
`dpe_ci_<suite>_<run_id>a<run_attempt>`, so:

- two suites of the same run never share a schema (the suite name is in the prefix);
- a re-run never reuses the schema of the attempt it replaced (`run_attempt` is in the token);
- two runs of the same suite never share one (`run_id`).

The earlier shape - `dpe_ci_<run_number>` with no `MC_RUN_ID` - left the only difference
between two matrix jobs in the UTC second the entrypoint appended, so jobs starting in the
same second were handed the same schema and would create and drop each other's relations.
A run that failed for that reason said nothing about the rules under test.
`tests/gate/schema_uniqueness.py` reads the workflow file and fails if any two simulated
jobs compose the same name, so the collision cannot come back unnoticed.

## Two repository settings the workflow needs

`.github/workflows/maxcompute-integration.yml` gates on configuration before it spends
any warehouse time:

1. repository **variables** `MC_PROJECT` and `MC_ENDPOINT`;
2. repository **secrets** `MAXCOMPUTE_ACCESS_ID` and `MAXCOMPUTE_ACCESS_KEY`.

If either is missing, a push or a manual run fails with `integration: BLOCKED` rather than
reporting green. A pull request from a fork can never read those secrets, so that case is
labelled `integration: NOT RUN` in the run summary and a maintainer runs the same suites with
*Run workflow*.

## Why not the tox targets

`tox.ini` / `run_tox_tests.sh` drive the adapters whose suites can run against the committed
`integration_tests/profiles.yml`. MaxCompute runs through
`scripts/run-maxcompute-integration-tests.sh` instead, which writes the profile into a temp
directory at run time and deletes it on exit. Why that choice, stated accurately:

- `auth_type: chain` keeps credentials in the environment, and generating the profile means no
  endpoint/project/secret combination ever has to be committed or hand-edited;
- a run can own its own `MC_SCHEMA_MC_RUN_ID` schema, which is what makes concurrent runs safe;
- **not** because Jinja in `profiles.yml` is broken. An earlier draft of this page claimed
  dbt-core 1.11 stopped rendering it; that is wrong and was measured on 1.11.2: an undefined
  `{{ env_var('…') }}` fails the parse with `Env var required but not provided`, and a defined one
  resolves (`dbt debug` reports `project: probe_project`). Proof: the two discriminators in
  `scripts/probe-profiles-jinja.sh` in this repository.

## Narrowing a manual run

A *Run workflow* `suites` input is honoured by `scripts/ci-select-suites.sh`:

| input | behaviour |
| --- | --- |
| empty | the measured default set: `integration_tests`, `integration_tests_2`, `integration_tests_minimal`, `integration_tests_empty` |
| one or more names (space separated) | exactly those suites |
| a name that is not a suite of this repository, or contains odd characters | the prepare step fails, nothing runs |
| whitespace only | fails as a usage error — it must not silently mean "run everything" (~47 min of warehouse time) |
| a suite that exists but has not been measured on MaxCompute yet | allowed only when named explicitly, with a note in the log |

The default list is deliberately an explicit one rather than "every `integration_tests*`
directory", so adding a project cannot silently put an unmeasured suite into CI. The selection is
a script instead of inline workflow YAML so those rules are testable without GitHub.

## Version combination

The suites were written against `dbt-core 1.11.2` with `dbt-maxcompute` and a three-tier
MaxCompute project. `require-dbt-version` in `dbt_project.yml` is the contract; the workflow
installs the pinned combination above.

## Notes for anyone changing the package

- MaxCompute refuses the implicit `DOUBLE -> FLOAT` narrowing. The graph staging models declare
  `sql_complexity` with `dbt.type_float()` and then insert values computed from the manifest, so the
  insert is rejected (`ODPS-0130071 … incompatible type DOUBLE with destination column sql_complexity,
  which has type FLOAT`) and every rule downstream is skipped. The fix casts the emitted values to the
  declared column type (`cast(<n> as {{ dbt.type_int() }})` / `dbt.type_float()`) in
  `macros/unpack/get_node_values.sql` and `macros/unpack/get_column_values.sql` - the same approach
  upstream took in #602, so this fork does not diverge on it.
- The profile is generated at run time (temp dir, `auth_type: chain`) so nothing about the
  warehouse or its credentials is committed; `env_var()` in `profiles.yml` does still work on
  dbt-core 1.11.2, measured - so this is a design choice, not a workaround.
- The exceptions seed is matched with `not like`, and `_` is a single-character wildcard in
  `LIKE`. Fixture names that rely on exemptions are therefore distinct enough not to collide.
