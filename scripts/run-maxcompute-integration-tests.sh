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
#   DPE_DEPS_ATTEMPTS optional `dbt deps` retries (default 5)
#   DPE_GIT_SSH   optional set 1 to reach git packages over ssh when the HTTPS
#                 clone path is blocked (needs a GitHub key on the account)
# Credentials are read from the environment by the adapter's ``auth_type: chain``
# (ODPS_ACCESS_ID / ODPS_ACCESS_KEY, or ALIBABA_CLOUD_ACCESS_KEY_ID / _SECRET);
# the generated profile holds no secret material and lives in a temp dir.
#
# A suite counts as passed only if run_results.json was written by THIS invocation (a
# previous run's file is removed before building), contains at least one executed node, has no
# errored/failed/unknown-status node, and dbt itself exited 0.
# An empty result list, an all-skipped suite and a non-zero dbt exit are failures;
# they used to be reported as passes, which is the whole reason this entrypoint
# exists.
#
# On top of that, a run whose executed nodes include model/seed/snapshot ones has to
# leave at least one relation in the schema it owns. Results alone cannot show that:
# dropping an empty schema is trivially successful, so a schema-resolution regression
# would have printed GATE=PASS while the work landed somewhere else.
#
# Exit codes: 0 every suite passed | 1 a node failed or errored, a suite produced no
# executed result, dbt exited non-zero, or the run schema held nothing although relation-
# bearing nodes reported executed | 2 blocked, no SQL reached a project
# (missing env/credentials, unreachable or two-tier project, or a run schema that is
# not a single safe identifier).
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
# A run owns its schema. The default token is second-resolution, which is enough for a
# person typing one command but NOT enough for a CI matrix: two suite jobs that start in
# the same second would be handed the same schema and would create and drop each other's
# relations. So a run id is required to carry more than the clock, and the composed name
# is validated below rather than trusted.
MC_RUN_ID="${MC_RUN_ID:-$(date -u +%Y%m%d%H%M%S)_$$}"
RUN_SCHEMA="${MC_SCHEMA}_${MC_RUN_ID}"
case "$RUN_SCHEMA" in
    *[!a-zA-Z0-9_]*)
        die_blocked "run schema '$RUN_SCHEMA' is not a plain identifier (letters, digits, underscore only). Set MC_SCHEMA and MC_RUN_ID so that MC_SCHEMA_MC_RUN_ID is one; a name carrying a separator would collide across suites on servers that fold identifiers."
        ;;
esac
if [ "${#RUN_SCHEMA}" -gt 64 ]; then
    die_blocked "run schema '$RUN_SCHEMA' is ${#RUN_SCHEMA} characters; MaxCompute caps a schema name at 128 but a name this long is a sign that MC_RUN_ID was built from the wrong fields (keep it under 64)"
fi

# Both fixture projects use the profile name "integration_tests", so one
# generated profile covers all of them. It is generated (and deleted on exit) so that
# nothing about the project, endpoint or credentials has to be committed or hand-edited;
# env_var() in profiles.yml does work on dbt-core 1.11.2 - verified here with two
# discriminators (undefined var fails the parse, defined var resolves) - so this is a
# credentials-isolation choice, not a workaround for a Jinja regression.
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
if [ "${DPE_GIT_SSH:-0}" = "1" ]; then
    export GIT_CONFIG_COUNT=1
    export GIT_CONFIG_KEY_0='url.git@github.com:.insteadOf'
    export GIT_CONFIG_VALUE_0='https://github.com/'
    echo "GIT: https://github.com/ rewritten to ssh for this run (DPE_GIT_SSH=1)"
fi

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
SUITES_WITH_PROJECT=0
# How many executed nodes are supposed to leave a relation behind (model/seed/snapshot).
# Cross-checked against the contents of the run schema below: results that say "40 models
# built" while the schema this run owns is empty did not land where the gate claims.
MATERIALIZING_TOTAL=0
CREATED_SCHEMAS=()
if [ "$SCHEMA_OWNED_BY_RUN" = "true" ]; then
    CREATED_SCHEMAS=("$RUN_SCHEMA")
fi
for suite in "${SUITES[@]}"; do
    project_dir="$REPO_ROOT/$suite"
    if [ ! -f "$project_dir/dbt_project.yml" ]; then
        # Requested but absent is a broken invocation, not a skipped suite: if it were
        # allowed to pass quietly, deleting or renaming one suite would take a unit of
        # coverage with it and leave the gate green.
        echo "SUITE $suite: NOT-PRESENT (no dbt_project.yml under $project_dir) - counted as a failure"
        OVERALL=1
        continue
    fi
    echo ""
    echo "=== SUITE $suite ==="
    SUITES_WITH_PROJECT=$((SUITES_WITH_PROJECT + 1))
    # Only this invocation's results are evidence. dbt writes target/run_results.json at the
    # END of a run, so a build that is interrupted, times out or dies leaves the previous run's
    # file sitting there - and this entrypoint would then read it and print GATE=PASS for work
    # it never did. Measured: a build killed by the timeout here printed `GATE=PASS 62 node(s)
    # executed` off a file whose own metadata said the invocation started 11 days earlier.
    # Removing that one generated file (nothing else in target/) is what makes "no results were
    # written" reportable as NOT-RUN instead of as somebody else's green run.
    if [ -f "$project_dir/target/run_results.json" ]; then
        rm -f "$project_dir/target/run_results.json" \
            && echo "SUITE $suite: stale run_results.json from a previous invocation removed before building" \
            || echo "SUITE $suite: COULD-NOT-REMOVE stale run_results.json - results below may not belong to this run"
    fi
    # `dbt deps` clones git packages over TLS and that transport flakes - or is
    # blocked outright - on shared runners and dev boxes, so it is retried before
    # the suite is called a failure. A suite that never got its packages reports
    # NOT-RUN; it is never a pass.
    # DPE_GIT_SSH=1 rewrites https://github.com/ to the ssh transport for this
    # run only (env-scoped, no repository or global git config is touched), which
    # is the fallback when the 443 clone path is blocked but ssh works.
    deps_rc=1
    for attempt in $(seq 1 "${DPE_DEPS_ATTEMPTS:-5}"); do
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
    if [ $build_rc -ne 0 ]; then
        # dbt itself said no (interrupted, a compile error, an aborted run). The run
        # results file may still describe that as zero failures, so the exit code is
        # recorded as its own failure here instead of being only printed.
        echo "SUITE $suite: BUILD-FAILED (dbt exited $build_rc) - counted as a failure even if run_results.json looks clean"
        OVERALL=1
    fi
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
    SUM_OUT="$("$PYTHON_BIN" "$SUPPORT" summary "$project_dir/target/run_results.json" "$suite")"
    SUM_RC=$?
    printf '%s\n' "$SUM_OUT"
    [ $SUM_RC -eq 0 ] || OVERALL=1
    # Parse the count out of the line the summary printed rather than re-deriving it here,
    # so there is exactly one place that decides what "materialising" means.
    MAT="$(printf '%s\n' "$SUM_OUT" \
        | sed -nE 's/^SUITE [^ ]+: MATERIALIZING=([0-9]+).*/\1/p' | head -1)"
    MATERIALIZING_TOTAL=$((MATERIALIZING_TOTAL + ${MAT:-0}))
done

echo ""
if [ "${SUITES_WITH_PROJECT:-0}" -eq 0 ]; then
    # Nothing was asked for and nothing ran. A gate that exits 0 here would report a
    # pass for a run that evaluated no rule at all.
    echo "INTEGRATION: FAIL - no suite ran (0 of ${#SUITES[@]} requested had a dbt_project.yml)"
    OVERALL=1
fi

# Where the work actually landed, read while the schemas are still alive.
# An all-empty run schema after executed relation-bearing nodes used to be invisible:
# the suites still reported GATE=PASS and cleanup still said OK (dropping an empty schema
# is trivially successful), so a resolved-schema regression - dbt writing to some other
# schema while this run "owned" an untouched one - would look exactly like a green run.
if [ "$MATERIALIZING_TOTAL" -gt 0 ]; then
    RS_OUT="$("$PYTHON_BIN" "$SUPPORT" count "$RUN_SCHEMA")"
    RS_RC=$?
    printf '%s\n' "$RS_OUT"
    RS_REL="$(printf '%s\n' "$RS_OUT" \
        | sed -nE 's/^RUN-SCHEMA: schema=[^ ]+ relations=([0-9]+)$/\1/p' | head -1)"
    if [ $RS_RC -ne 0 ]; then
        # Unreadable or missing is its own failure: defaulting it to "empty" would let a
        # broken read masquerade as the very finding this check exists to report.
        echo "RUN-SCHEMA: UNREADABLE (rc=$RS_RC) - $MATERIALIZING_TOTAL relation-bearing node(s) ran and the schema could not be read; counted as a failure"
        OVERALL=1
    elif [ "${RS_REL:-0}" -eq 0 ]; then
        echo "RUN-SCHEMA: EMPTY - $MATERIALIZING_TOTAL relation-bearing node(s) reported executed, yet schema $RUN_SCHEMA holds 0 relations: the run did not land in the schema it owns (not a pass)"
        OVERALL=1
    fi
else
    echo "RUN-SCHEMA: SKIPPED (no model/seed/snapshot node executed, so nothing was expected to materialise in $RUN_SCHEMA)"
fi

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
