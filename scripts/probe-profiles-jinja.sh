#!/usr/bin/env bash
# **what?** Two discriminators for one claim about `profiles.yml`: does dbt render Jinja there?
# **why?** This page used to say MaxCompute generates its profile because "dbt-core 1.11 stopped
#        rendering Jinja in profiles.yml". That claim needed a measurement, not a memory - and the
#        measurement says the claim was wrong, so the docs now say so and this script is the proof.
# **when?** Run it whenever a docs statement about profile rendering is being (re)written:
#   ./scripts/probe-profiles-jinja.sh
#
# It writes only into a temp directory, never contacts a warehouse, and prints:
#   UNDEFINED-VAR-RC  -> non-zero with "Env var required but not provided" means Jinja IS rendered
#   PROJECT_LINE      -> the resolved value, e.g. "project: probe_project", means the same thing
set -uo pipefail
DBT="${DBT_BIN:-dbt}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/proj/models" "$TMP/profiles" "$TMP/profiles2"
cat > "$TMP/proj/dbt_project.yml" <<'YML'
name: 'jinja_probe'
version: '1.0.0'
config-version: 2
profile: 'jinja_probe'
model-paths: ["models"]
YML
echo "select 1 as id" > "$TMP/proj/models/m.sql"

emit_profile() {  # emit_profile <dir> <project-value>
    cat > "$1/profiles.yml" <<YML
jinja_probe:
  target: dev
  outputs:
    dev:
      type: maxcompute
      project: $2
      schema: dpe_probe_never_used
      endpoint: "http://service.invalid/api"
      auth_type: chain
      threads: 1
YML
}

export MC_PROBE_VALUE=probe_project
emit_profile "$TMP/profiles" '"{{ env_var('"'"'MC_PROBE_VALUE'"'"') }}"'
emit_profile "$TMP/profiles2" '"{{ env_var('"'"'MC_PROBE_DEFINITELY_UNDEFINED'"'"') }}"'

echo "== discriminator 1: an undefined env_var must blow up *if* Jinja is rendered"
"$DBT" parse --project-dir "$TMP/proj" --profiles-dir "$TMP/profiles2" --quiet 2>&1 | tail -2 | cut -c1-160
echo "UNDEFINED-VAR-RC=${PIPESTATUS[0]}"

echo
echo "== discriminator 2: print the value dbt actually resolved"
    out="$("$DBT" debug --project-dir "$TMP/proj" --profiles-dir "$TMP/profiles" 2>&1)"
    printf '%s\n' "$out" | grep -E "project: |endpoint: " | head -3 | sed "s/^[[:space:]]*/  /"
echo "PROJECT_LINE 上面若显示 probe_project，则 env_var 被渲染"
