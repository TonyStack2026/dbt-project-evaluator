# run_results.json fixtures used by scripts/test-mc-integration-gate.sh.
# Shape matches what dbt-core 1.11 writes: a top-level "results" list whose entries
# carry "unique_id" and "status".
fixture_empty() {
    cat <<'JSON'
{"metadata": {"dbt_schema_version": "https://schemas.getdbt.com/dbt/run-results/v6.json"}, "results": []}
JSON
}

fixture_all_skipped() {
    cat <<'JSON'
{"results": [
  {"unique_id": "model.dpe.a", "status": "skipped", "message": null},
  {"unique_id": "model.dpe.b", "status": "skipped", "message": null},
  {"unique_id": "test.dpe.c", "status": "no-op", "message": null}
]}
JSON
}

fixture_clean_pass() {
    cat <<'JSON'
{"results": [
  {"unique_id": "model.dpe.a", "status": "success", "message": null},
  {"unique_id": "test.dpe.b", "status": "pass", "message": null},
  {"unique_id": "test.dpe.c", "status": "warn", "message": "1 warning"}
]}
JSON
}

fixture_one_fail() {
    cat <<'JSON'
{"results": [
  {"unique_id": "model.dpe.a", "status": "success", "message": null},
  {"unique_id": "test.dpe.b", "status": "fail", "message": "not null failed: 2 errors"}
]}
JSON
}

# The statuses a live run actually wrote (155-node suite against a real three-tier
# project, dbt-core 1.11.2): `success` for models, `pass` for tests, `no-op` with the
# hyphen for the one exposure dbt declined to run. A green run has to stay green, so this
# fixture is the counterweight to every "make the gate stricter" change.
fixture_real_live_shape() {
    cat <<'JSON'
{"results": [
  {"unique_id": "model.dbt_project_evaluator_integration_tests.dag_health__base", "status": "success", "message": null},
  {"unique_id": "test.dbt_project_evaluator_integration_tests.dpe_unused_source", "status": "pass", "message": "PASS=1"},
  {"unique_id": "test.dbt_project_evaluator_integration_tests.dpe_undocumented", "status": "warn", "message": "WARN"},
  {"unique_id": "exposure.dbt_project_evaluator_integration_tests.exposure_1", "status": "no-op", "message": null}
]}
JSON
}

fixture_unknown_status() {
    cat <<'JSON'
{"results": [
  {"unique_id": "model.dpe.a", "status": "success", "message": null},
  {"unique_id": "model.dpe.b", "status": "interrupted", "message": "database error"}
]}
JSON
}

# A suite made only of tests/sources: nodes execute and pass, and nothing in it is
# supposed to create a table or view. This is the counterweight for the run-schema
# check - without it the guard would demand relations from a suite that has none to create.
# Naming note, measured on a live project 2026-10-25: `integration_tests_empty` is NOT such a
# suite - it reports MATERIALIZING=49 and its own schema held 49 relations (dbt build still
# materialises the package's own models there; "empty" means no findings, not no relations).
# So this case protects the branch in general; no shipped suite currently reaches SKIPPED.
fixture_tests_only() {
    cat <<'JSON'
{"results": [
  {"unique_id": "test.dpe.a", "status": "pass", "message": "PASS=1"},
  {"unique_id": "test.dpe.b", "status": "warn", "message": "WARN"},
  {"unique_id": "source.dpe.c", "status": "success", "message": null}
]}
JSON
}
