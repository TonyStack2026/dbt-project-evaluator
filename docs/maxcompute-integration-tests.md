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

- `MC_RUN_ID` — suffix for this run's schema (default: UTC timestamp). Concurrent runs stay
  isolated because each one owns `MC_SCHEMA_MC_RUN_ID`.
- `MC_KEEP_SCHEMAS=1` — leave the run's schema in place for inspection.
- `DPE_ARTIFACT_DIR` — copy each `run_results.json` here.
- `DPE_DBT_EXTRA` — extra dbt build flags, e.g. `--select tag:my_subset`.

Exit codes:

| Code | Meaning |
| --- | --- |
| 0 | every suite ran against the project and passed |
| 1 | at least one suite had an error or a failed test |
| 2 | **blocked**: no credentials, no `MC_PROJECT`/`MC_ENDPOINT`, the project is unreachable, or it is a two-tier project. No SQL ran, so this is not a pass. |

A blocked run is reported as `INTEGRATION: BLOCKED - <reason>`; a suite whose packages could
not be installed is reported as `SUITE <name>: NOT-RUN`. Both are distinct from "0 nodes
failed", which is what a passing run says.

Cleanup is ownership-based: the entrypoint records whether *this* run created the schema and
only drops what it created, then re-reads the project to prove nothing survived. A schema that
already existed is left alone, because another run may be using it.

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

`tox.ini` / `run_tox_tests.sh` drive the adapters whose outputs can be produced by
`dbt build -t <adapter>` against the committed `integration_tests/profiles.yml`. That file
resolves its settings with `{{ env_var(...) }}`, which dbt-core 1.11+ no longer renders, and a
MaxCompute profile needs `auth_type: chain` so that no key material is ever written into the
repository. MaxCompute therefore runs through `scripts/run-maxcompute-integration-tests.sh`,
which generates the profile at run time in a temp directory and cleans it up on exit.

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
- dbt-core 1.11 stopped rendering Jinja in `profiles.yml`, which is why the profile is
  generated at run time instead of being committed with `env_var()` calls.
- The exceptions seed is matched with `not like`, and `_` is a single-character wildcard in
  `LIKE`. Fixture names that rely on exemptions are therefore distinct enough not to collide.
