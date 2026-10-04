#!/usr/bin/env bash
# **what?**
# Prove the MaxCompute integration gate fails when there is nothing to believe:
# an empty result list, an all-skipped suite, a non-zero dbt exit, a missing
# run_results.json, a requested suite that is not there, a failed `dbt deps`, and a run
# schema that is not one safe identifier. Also prove the two shapes that must stay
# usable: a clean suite is green, and two matrix jobs running in parallel own different
# schemas. Reads the workflow file to check the schema names a real matrix would compose.
#
# **why?**
# The point of the entrypoint is to tell "the rules produced the expected rows" apart
# from "no SQL ever ran". A gate that returns 0 for zero rows cannot do that, and the
# only way to know a gate still has teeth is to run it against every false-green shape it
# is meant to catch. Nothing here needs a warehouse, credentials, pyodps or network, so
# it also holds on a fork pull request, where no real run is possible at all.
#
# **when?**
# By the `gate-selftest` job of .github/workflows/maxcompute-integration.yml (runs on
# every pull request), and locally:
#
#   ./scripts/test-mc-integration-gate.sh                       # this working tree
#   ./scripts/test-mc-integration-gate.sh /path/to/scripts /path/to/workflow   # A/B
#
# Exit codes: 0 every expectation held | 1 at least one did not | 2 missing test input.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UNDER="${1:-$REPO_ROOT/scripts}"
WORKFLOW="${2:-$REPO_ROOT/.github/workflows/maxcompute-integration.yml}"
REAL_SUPPORT="$UNDER/mc_integration_support.py"
GATE_SCRIPT="$UNDER/run-maxcompute-integration-tests.sh"
FIXTURES="$REPO_ROOT/tests/gate/fixtures.sh"
FAKE_ODPS="$REPO_ROOT/tests/gate/fake_odps.py"
SCHEMA_TEST="$REPO_ROOT/tests/gate/schema_uniqueness.py"
PYTHON_BIN="${PYTHON_BIN:-python3}"

for required in "$REAL_SUPPORT" "$GATE_SCRIPT" "$FIXTURES" "$FAKE_ODPS" "$SCHEMA_TEST" "$WORKFLOW"; do
    [ -f "$required" ] || { echo "SETUP: FAIL missing $required"; exit 2; } done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Same warehouse double, but reachable without building a whole repo: a pre-fix copy of
# the support script imported pyodps at module scope, and without this shim an A/B run
# would "fail" for a missing dependency rather than for the gate logic being tested.
SHIM="$WORK/shim"
mkdir -p "$SHIM"
cp "$FAKE_ODPS" "$SHIM/odps.py"
CHECKS=0
FAILURES=0

ok()  { CHECKS=$((CHECKS + 1)); printf '  ok    %s\n' "$1"; }
bad() { CHECKS=$((CHECKS + 1)); FAILURES=$((FAILURES + 1)); printf '  FAIL  %s\n' "$1"; }
show() { printf '%s\n' "$2" | tail -16 | sed 's/^/        | /'; }

# shellcheck source=/dev/null
. "$FIXTURES"

echo "== gate self-test"
echo "   scripts  : $UNDER"
echo "   workflow : $WORKFLOW"
echo ""

# ---------------------------------------------------------------- summary() verdicts
summary_case() {
    local name="$1" expected="$2" needle="$3" json="$4" file rc out
    file="$WORK/$name.json"
    printf '%s\n' "$json" > "$file"
    out="$(PYTHONPATH="$SHIM" "$PYTHON_BIN" "$REAL_SUPPORT" summary "$file" "$name" 2>&1)"; rc=$?
    if [ "$rc" -ne "$expected" ]; then
        bad "summary/$name exited $rc, expected $expected"; show "$name" "$out"
    elif [ -n "$needle" ] && ! grep -qF -- "$needle" <<<"$out"; then
        bad "summary/$name exited $rc but never says '$needle'"; show "$name" "$out"
    else
        ok "summary/$name exited $rc and says '$needle'"
    fi
}

echo "-- summary(): one case per false-green shape"
summary_case empty_results  1 "no node produced a result"    "$(fixture_empty)"
summary_case all_skipped    1 "every node was skipped/no-op" "$(fixture_all_skipped)"
summary_case one_fail       1 "NOT-PASS"                     "$(fixture_one_fail)"
summary_case unknown_status 1 "NOT-PASS"                     "$(fixture_unknown_status)"
summary_case clean_pass     0 "GATE=PASS"                    "$(fixture_clean_pass)"
summary_case real_live_shape 0 "GATE=PASS"                   "$(fixture_real_live_shape)"

# ----------------------------------------------------- the entrypoint as a whole
# A repo-shaped temp directory, so the entrypoint resolves its suites exactly as in CI.
# `dbt` is a script that obeys the mode handed to it; the warehouse SDK is doubled by
# tests/gate/fake_odps.py, which is on PYTHONPATH as `odps`. The preflight and cleanup
# code paths under test are the real ones - only the server is fake.
build_repo() {
    local repo="$1" suite
    mkdir -p "$repo/scripts" "$repo/bin" "$repo/results" "$repo/shim"
    cp "$GATE_SCRIPT" "$REAL_SUPPORT" "$repo/scripts/"
    cp "$FAKE_ODPS" "$repo/shim/odps.py"
    for suite in fake_suite second_suite; do
        mkdir -p "$repo/$suite"
        printf 'name: %s\nversion: "1.0.0"\n' "$suite" > "$repo/$suite/dbt_project.yml"
    done
    cat > "$repo/bin/dbt" <<'FAKE_DBT'
#!/usr/bin/env python3
"""dbt stand-in: answers the two subcommands the entrypoint calls, nothing else."""
import os
import shutil
import sys

sub = sys.argv[1] if len(sys.argv) > 1 else ""
mode = os.environ.get("GATE_MODE", "clean_pass")

if sub == "deps":
    print("fake dbt deps: mode=%s" % mode)
    sys.exit(1 if mode == "deps_fails" else 0)

if sub == "build":
    target = sys.argv[sys.argv.index("--target") + 1] if "--target" in sys.argv else "?"
    print("fake dbt build: mode=%s target=%s" % (mode, target))
    if mode != "no_results_file":
        os.makedirs("target", exist_ok=True)
        source = os.path.join(os.environ["GATE_RESULTS_DIR"], mode + ".json")
        if os.path.exists(source):
            shutil.copyfile(source, "target/run_results.json")
        else:
            open("target/run_results.json", "w").write('{"results": []}')
    sys.exit(int(os.environ.get("GATE_DBT_RC", "0")))

print("fake dbt: unexpected call %r" % (sys.argv[1:],))
sys.exit(0)
FAKE_DBT
    chmod +x "$repo/bin/dbt"
    local pair
    for pair in empty_results all_skipped one_fail clean_pass real_live_shape build_failed no_results_file deps_fails; do
        case "$pair" in
            empty_results) printf '%s\n' "$(fixture_empty)"        > "$repo/results/$pair.json" ;;
            all_skipped)   printf '%s\n' "$(fixture_all_skipped)"  > "$repo/results/$pair.json" ;;
            one_fail)      printf '%s\n' "$(fixture_one_fail)"     > "$repo/results/$pair.json" ;;
            *)             printf '%s\n' "$(fixture_clean_pass)"   > "$repo/results/$pair.json" ;;
        esac
    done
}

# gate_run <repo> <log file> <mode> <suites...> -- extra env as NAME=value before the call
gate_run() {
    local repo="$1" log="$2" mode="$3"; shift 3
    env PATH="$repo/bin:$PATH" \
        PYTHONPATH="$repo/shim" \
        PYTHON_BIN="$PYTHON_BIN" \
        FAKE_ODPS_STATE="$repo/fake-odps-state.json" \
        MC_PROJECT=stub-project MC_ENDPOINT=http://stub-endpoint \
        ODPS_ACCESS_ID=stub-id ODPS_ACCESS_KEY=stub-key \
        MC_SCHEMA=dpe_ci MC_RUN_ID="$mode" \
        GATE_MODE="$mode" GATE_RESULTS_DIR="$repo/results" GATE_DBT_RC=0 \
        DPE_DEPS_ATTEMPTS=1 \
        "$repo/scripts/run-maxcompute-integration-tests.sh" "$@" > "$log" 2>&1
}

gate_case() {
    local name="$1" mode="$2" expected="$3" needle="$4" suites="$5"; shift 5
    local repo="$WORK/repo-$name" log="$WORK/$name.log" rc out
    build_repo "$repo"
    out="$(env PATH="$repo/bin:$PATH" PYTHONPATH="$repo/shim" PYTHON_BIN="$PYTHON_BIN" \
            FAKE_ODPS_STATE="$repo/fake-odps-state.json" \
            MC_PROJECT=stub-project MC_ENDPOINT=http://stub-endpoint \
            ODPS_ACCESS_ID=stub-id ODPS_ACCESS_KEY=stub-key \
            MC_SCHEMA=dpe_ci MC_RUN_ID="$mode" \
            GATE_MODE="$mode" GATE_RESULTS_DIR="$repo/results" GATE_DBT_RC=0 \
            DPE_DEPS_ATTEMPTS=1 "$@" \
            "$repo/scripts/run-maxcompute-integration-tests.sh" $suites 2>&1)"; rc=$?
    printf '%s\n' "$out" > "$log"
    if [ "$rc" -ne "$expected" ]; then
        bad "gate/$name exited $rc, expected $expected"; show "$name" "$out"
    elif [ -n "$needle" ] && ! grep -qF -- "$needle" <<<"$out"; then
        bad "gate/$name exited $rc but never says '$needle'"; show "$name" "$out"
    else
        ok "gate/$name exited $rc and says '$needle'"
    fi
}

echo ""
echo "-- run-maxcompute-integration-tests.sh: one case per false-green shape"
gate_case clean_pass      clean_pass      0 "GATE=PASS"                          fake_suite
gate_case real_live_shape real_live_shape 0 "GATE=PASS"                          fake_suite
gate_case empty_results   empty_results   1 "no node produced a result"           fake_suite
gate_case all_skipped     all_skipped     1 "every node was skipped/no-op"        fake_suite
gate_case build_failed    build_failed    1 "BUILD-FAILED"                        fake_suite GATE_DBT_RC=1
gate_case no_results_file no_results_file 1 "NOT-RUN (dbt wrote no run_results.json)" fake_suite
gate_case deps_fails      deps_fails      1 "NOT-RUN (packages could not be installed)" fake_suite
gate_case missing_suite   clean_pass      1 "NOT-PRESENT"                         nope_suite
gate_case unsafe_schema   clean_pass      2 "not a plain identifier"              fake_suite MC_RUN_ID="1234-5678"

# ------------------------------------------------- schemas a run creates and drops
# The ownership rule is what keeps a suite from deleting somebody else's warehouse, so
# it is asserted from the fake server's state, not from the log's wording.
echo ""
echo "-- schema ownership"
iso_repo="$WORK/repo-schema-ownership"; iso_log="$WORK/schema-ownership.log"
build_repo "$iso_repo"
gate_run "$iso_repo" "$iso_log" clean_pass fake_suite; iso_rc=$?
CHECKS=$((CHECKS + 1))
if [ $iso_rc -ne 0 ]; then
    bad "gate/schema-ownership run exited $iso_rc, expected 0"; show "schema-ownership" "$(cat "$iso_log")"
else
    got="$("$PYTHON_BIN" - "$iso_repo/fake-odps-state.json" <<'PY'
import json,sys
state=json.load(open(sys.argv[1]))
print("leftover=%d" % len(state["schemas"]))
PY
)"
    if [ "$got" != "leftover=0" ]; then
        bad "the run left its schema behind ($got) - cleanup is supposed to drop what it created"
    elif ! grep -qF "CLEANUP: OK dropped 1 schema(s) owned by this run: dpe_ci_clean_pass" "$iso_log"; then
        bad "cleanup did not report dropping exactly this run's schema"; show "schema-ownership" "$(cat "$iso_log")"
    else
        ok "run created exactly its own schema (dpe_ci_clean_pass) and dropped it again"
    fi
fi

# A pre-existing schema must not be touched: that is another run's data.
pre_repo="$WORK/repo-preexisting"; pre_log="$WORK/preexisting.log"
build_repo "$pre_repo"
FAKE_ODPS_DIR="$(cd "$(dirname "$FAKE_ODPS")" && pwd)"     "$PYTHON_BIN" - "$pre_repo/fake-odps-state.json" <<'PY'
import os, sys
sys.path.insert(0, os.environ["FAKE_ODPS_DIR"])
import fake_odps
fake_odps.seed_relation(sys.argv[1], "dpe_ci_clean_pass", "somebody_elses_table")
PY
gate_run "$pre_repo" "$pre_log" clean_pass fake_suite
CHECKS=$((CHECKS + 1))
if grep -qE "CLEANUP: (OK dropped|FAIL)" "$pre_log" && grep -q "dropped schema dpe_ci_clean_pass" "$pre_log"; then
    bad "the run dropped a schema it did not create"; show "preexisting" "$(cat "$pre_log")"
elif ! grep -qF "CLEANUP: OK nothing to drop" "$pre_log"; then
    bad "cleanup did not report leaving the pre-existing schema alone"; show "preexisting" "$(cat "$pre_log")"
else
    ok "a schema that already existed was left alone, including the relation inside it"
fi

# ------------------------------------------- the schemas a CI matrix would compose
echo ""
echo "-- schema isolation across the matrix"
"$PYTHON_BIN" "$SCHEMA_TEST" "$WORKFLOW"
schema_rc=$?
CHECKS=$((CHECKS + 1))
if [ $schema_rc -eq 0 ]; then ok "schema_uniqueness: every matrix job composes its own schema"; else bad "schema_uniqueness exited $schema_rc"; fi

echo ""
echo "INTEGRATION GATE SELF-TEST: checks=$CHECKS failures=$FAILURES"
[ "$FAILURES" -eq 0 ] || { echo "status: FAILED (the gate does not hold)"; exit 1; }
echo "status: PASSED (every false-green shape is caught; the clean run is still green)"
