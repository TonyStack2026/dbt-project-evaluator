#!/usr/bin/env bash
# **what?**
# Run this package's integration suites against a live MaxCompute project and
# report the actual rule results, instead of "tested manually".
#
# **why?**
# The package supports MaxCompute but had no replayable way to prove it: a run
# either reached the server or it did not, and nothing distinguished
# "0 nodes ran" from "everything passed".
#
# **when?**
# Locally before opening a pull request, and from
# .github/workflows/maxcompute-integration.yml on push / pull request / manual run.
#
# Environment (never write these into the repository):
#   MC_PROJECT    required  three-tier MaxCompute project (project + schemas)
#   MC_ENDPOINT   required  service endpoint
#   MC_SCHEMA     optional  schema prefix for this run  (default dbt_project_evaluator_it)
#   MC_RUN_ID     optional  run suffix                  (default UTC timestamp)
#   MC_KEEP_SCHEMAS optional set 1 to keep this run's schemas for inspection
#   DPE_ARTIFACT_DIR optional directory to copy each run_results.json into
#   DPE_DBT_EXTRA optional extra dbt flags, e.g. "--select tag:my_subset"
# Credentials are read from the environment by the adapter's ``auth_type: chain``
# (ODPS_ACCESS_ID / ODPS_ACCESS_KEY, or ALIBABA_CLOUD_ACCESS_KEY_ID / _SECRET);
# the generated profile holds no secret material and lives in a temp dir.
#
# Exit codes: 0 every suite passed | 1 a node failed or errored | 2 blocked, no
# SQL reached a project (missing env/credentials, unreachable or two-tier project).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUPPORT="$REPO_ROOT/scripts/mc_integration_support.py"
PYTHON_BIN="${PYTHON_BIN:-python3}"
DBT_BIN="${DBT_BIN:-dbt}"

die_blocked() {
    echo "INTEGRATION: BLOCKED - $1" >&2
    echo "" >> "${GITHUB_STEP_SUMMARY:-/dev/null}" 2>/dev/null || true
    echo "## integration: BLOCKED" >> "${GITHUB_STEP_SUMMARY:-/dev/null}" 2>/dev/null || true
    echo "- $1" >> "${GITHUB_STEP_SUMMARY:-/dev/null}" 2>/dev/null || true
    echo "- No SQL reached a MaxCompute project. **This is not an integration pass.**" \
        >> "${GITHUB_STEP_SUMMARY:-/dev/null}" 2>/dev/null || true
    exit 2
}

[ -n "${MC_PROJECT:-}" ] || die_blocked "MC_PROJECT is not set"
[ -n "${MC_ENDPOINT:-}" ] || die_blocked "MC_ENDPOINT is not set"
if [ -z "${ODPS_ACCESS_ID:-}" ] && [ -n "${ALIBABA_CLOUD_ACCESS_KEY_ID:-}" ]; then
    export ODPS_ACCESS_ID="$ALIBABA_CLOUD_ACCESS_KEY_ID"
    export ODPS_ACCESS_KEY="${ALIBABA_CLOUD_ACCESS_KEY_SECRET:-}"
fi
[ -n "${ODPS_ACCESS_ID:-}" ] && [ -n "${ODPS_ACCESS_KEY:-}" ] \
    || die_blocked "no MaxCompute credentials in the environment"

MC_SCHEMA="${MC_SCHEMA:-dbt_project_evaluator_it}"
MC_RUN_ID="${MC_RUN_ID:-$(date -u +%Y%m%d%H%M%S)}"
RUN_SCHEMA="${MC_SCHEMA}_${MC_RUN_ID}"

# Both fixture projects use the profile name "integration_tests", so one
# generated profile covers all of them. dbt-core >= 1.11 does not render Jinja
# in profiles.yml, which is why this file is generated instead of checked in
# with env_var() calls.
PROFILES_DIR="$(mktemp -d)"
umask 077
cat > "$PROFILES_DIR/profiles.yml" <<YAML
integration_tests:
  target: maxcompute
  outputs:
    maxcompute:
      type: maxcompute
      project: ${MC_PROJECT}
      schema: ${RUN_SCHEMA}
      endpoint: ${MC_ENDPOINT}
      auth_type: chain
      threads: 4
YAML
export DBT_PROFILES_DIR="$PROFILES_DIR"
cleanup_profiles() { rm -rf "$PROFILES_DIR"; }
trap cleanup_profiles EXIT

echo "INTEGRATION: START project=$MC_PROJECT endpoint_host=${MC_ENDPOINT#*://} schema=$RUN_SCHEMA"
PREFLIGHT_OUT="$("$PYTHON_BIN" "$SUPPORT" preflight "$RUN_SCHEMA")"
PREFLIGHT_RC=$?
echo "$PREFLIGHT_OUT"
[ $PREFLIGHT_RC -eq 0 ] || die_blocked "preflight did not reach a usable project"
SCHEMA_OWNED_BY_RUN="$(printf '%s\n' "$PREFLIGHT_OUT" \
    | sed -nE 's/.*schema_created_by_this_run=([A-Za-z]+).*/\1/p')"
# Ownership of the run schema decides cleanup, so an unreadable marker must not
# default to "nothing to clean" - that would leak warehouse objects silently.
case "$SCHEMA_OWNED_BY_RUN" in
    true|false) ;;
    *) die_blocked "preflight did not report schema_created_by_this_run (refusing to run without a cleanup decision)" ;;
esac

SUITES=("$@")
if [ ${#SUITES[@]} -eq 0 ]; then
    SUITES=(integration_tests integration_tests_2 integration_tests_minimal integration_tests_empty)
fi

OVERALL=0
CREATED_SCHEMAS=()
if [ "$SCHEMA_OWNED_BY_RUN" = "true" ]; then
    CREATED_SCHEMAS=("$RUN_SCHEMA")
fi
for suite in "${SUITES[@]}"; do
    project_dir="$REPO_ROOT/$suite"
    if [ ! -f "$project_dir/dbt_project.yml" ]; then
        echo "SUITE $suite: NOT-PRESENT (skipped, no dbt_project.yml)"
        continue
    fi
    echo ""
    echo "=== SUITE $suite ==="
    # `dbt deps` clones git packages over TLS and that transport flakes on
    # shared runners, so it is retried before the suite is called a failure.
    # A suite that never got its packages reports NOT-RUN; it is never a pass.
    deps_rc=1
    for attempt in 1 2 3; do
        (cd "$project_dir" && timeout 900 "$DBT_BIN" deps --quiet) 2>&1 \
            | sed -e "s/^/  deps attempt $attempt: /"
        deps_rc=${PIPESTATUS[0]}
        echo "SUITE $suite deps: rc=$deps_rc attempt=$attempt"
        [ $deps_rc -eq 0 ] && break
        sleep 15
    done
    if [ $deps_rc -ne 0 ]; then
        echo "SUITE $suite: NOT-RUN (packages could not be installed)"
        OVERALL=1
        continue
    fi
    (cd "$project_dir" && timeout 3600 "$DBT_BIN" build --target maxcompute --full-refresh \
        ${DPE_DBT_EXTRA:-}); build_rc=$?
    echo "SUITE $suite build: rc=$build_rc"
    if [ ! -f "$project_dir/target/run_results.json" ]; then
        echo "SUITE $suite: NOT-RUN (dbt wrote no run_results.json)"
        OVERALL=1
        continue
    fi
    if [ -n "${DPE_ARTIFACT_DIR:-}" ]; then
        mkdir -p "$DPE_ARTIFACT_DIR"
        cp "$project_dir/target/run_results.json" \
           "$DPE_ARTIFACT_DIR/$suite-run_results.json" 2>/dev/null \
            && echo "SUITE $suite snapshot: $suite-run_results.json"
    fi
    "$PYTHON_BIN" "$SUPPORT" summary "$project_dir/target/run_results.json" "$suite"
    [ $? -eq 0 ] || OVERALL=1
done

echo ""
if [ "${MC_KEEP_SCHEMAS:-0}" = "1" ]; then
    echo "CLEANUP: SKIPPED (MC_KEEP_SCHEMAS=1), schemas left behind: ${CREATED_SCHEMAS[*]:-none}"
elif [ ${#CREATED_SCHEMAS[@]} -eq 0 ]; then
    echo "CLEANUP: OK nothing to drop (schema $RUN_SCHEMA pre-existed or was never created)"
else
    "$PYTHON_BIN" "$SUPPORT" cleanup "${CREATED_SCHEMAS[@]}" || OVERALL=1
fi

echo ""
echo "INTEGRATION RESULTS"
if [ $OVERALL -eq 0 ]; then
    echo "  status:  PASSED (real server-side results, see SUITE lines above)"
else
    echo "  status:  FAILED (at least one suite did not pass; see SUITE lines above)"
fi
exit $OVERALL
