#!/usr/bin/env bash
# **what?**
# Turns the "Run workflow" input into a GitHub Actions matrix for the MaxCompute suites.
#
# **why?**
# The workflow used to declare a `suites` input and then ignore it: a maintainer narrowing a
# manual run still paid for every suite (~47 minutes for the 155-node one). Selecting in a
# separate script also means the behaviour is testable without GitHub.
#
# **when?**
# Called by .github/workflows/maxcompute-integration.yml (prepare job), and locally:
#   ./scripts/ci-select-suites.sh                      # default: every suite in the repo
#   ./scripts/ci-select-suites.sh integration_tests_minimal
#
# Output (one line, written to GITHUB_OUTPUT when present):
#   matrix={"include":[{"suite":"integration_tests"},{"suite":"integration_tests_empty"}, ...]}
# The payload is an OBJECT, not a bare array, because the consumer is
# `strategy.matrix: ${{ fromJSON(needs.prepare.outputs.matrix) }}` and Actions requires that
# value to be an object - a top-level array makes the whole workflow file invalid, which would
# stop every matrix job from expanding the moment the credential gate lets the live job run.
# `tests/gate/matrix_contract.py` checks producer and consumer together, not each side alone.
# Exit codes: 0 selection produced | 1 an unknown / non-suite name was requested | 2 usage error
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The default for a manual/scheduled run is deliberately an explicit list of the suites that
# have been measured against a live MaxCompute project - discovery alone would silently add a
# project nobody has run there yet. Anything with a dbt_project.yml can still be requested
# explicitly, which is how a new suite gets measured before it joins the default.
MEASURED_SUITES=("integration_tests" "integration_tests_2" "integration_tests_minimal" "integration_tests_empty")

discover() {
    local dir
    for dir in "$REPO_ROOT"/integration_tests*; do
        [ -f "$dir/dbt_project.yml" ] || continue
        basename "$dir"
    done | sort
}

is_measured() {
    local candidate="$1" entry
    for entry in "${MEASURED_SUITES[@]}"; do
        [ "$entry" = "$candidate" ] && return 0
    done
    return 1
}

available="$(discover)"
if [ -z "$available" ]; then
    echo "SELECT: FAIL no suite directory with a dbt_project.yml was found under $REPO_ROOT" >&2
    exit 1
fi

requested=("$@")
# Only "no argument at all" means "use the default set". A whitespace-only argument is a typo in
# the Run-workflow field, not an empty input, so it falls through to the request branch below and
# is rejected with 2 rather than silently paying for every suite.
if [ ${#requested[@]} -eq 0 ]; then
    selected="$(printf '%s\n' "${MEASURED_SUITES[@]}" | sort)"
    source="default (measured suites)"
else
    selected=""
    for name in "${requested[@]}"; do
        name="${name%%/}"
        [ -n "$name" ] || continue
        if [ -z "${name// /}" ]; then
            echo "SELECT: FAIL the request was only whitespace, which is not the same as 'no input'" >&2
            exit 2
        fi
        case "$name" in
            *[!A-Za-z0-9_.-]*)
                echo "SELECT: REJECT '$name' is not a valid directory name" >&2
                exit 1 ;;
        esac
        if [ ! -f "$REPO_ROOT/$name/dbt_project.yml" ]; then
            echo "SELECT: REJECT '$name' is not a suite of this repository (available: $(echo $available))" >&2
            exit 1
        fi
        if ! is_measured "$name"; then
            echo "SELECT: note '$name' is not in the default set because it has not been measured against a live MaxCompute project yet; running it because it was requested explicitly" >&2
        fi
        selected="$selected"$'\n'"$name"
    done
    selected="$(printf '%s\n' "$selected" | sed '/^$/d' | sort -u)"
    source="requested"
    if [ -z "$selected" ]; then
        echo "SELECT: FAIL the request was only whitespace, which is not the same as 'no input'" >&2
        exit 2
    fi
fi

# Wrapped in `include` so the emitted value is an object (see the header): a bare array here is
# what the reviewer caught on 2026-11-05, and it had never surfaced because Actions is not enabled
# on the base repository, so nothing in this workflow has ever been expanded by a runner.
matrix='{"include":['
first=1
while IFS= read -r suite; do
    [ -n "$suite" ] || continue
    [ $first -eq 1 ] || matrix="$matrix,"
    first=0
    matrix="$matrix{\"suite\":\"$suite\"}"
done <<< "$selected"
matrix="$matrix]}"

echo "matrix=$matrix"
echo "SELECT: ok source=$source suites=$(printf '%s ' $selected)" >&2
