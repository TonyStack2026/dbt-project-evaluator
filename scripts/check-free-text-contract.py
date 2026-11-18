#!/usr/bin/env python3
"""Offline, credential-free contract checks for the free-text round-trip fix.

Two independent things, both runnable in CI without a warehouse:

 1. **Truth table for the assertion itself** (`integration_tests/tests/assert_free_text_roundtrip.sql`).
    The committed SQL is stripped of Jinja (only `ref()` and `dbt.hash()` are substituted), loaded
    into SQLite and executed against fake `stg_exposures` / `base_node_columns` tables. Each state
    that must fail does fail, with the expected reason, and the correct-value case returns zero
    rows. This exists because an `INNER JOIN`-shaped version of this test passed on an empty
    actual set and on NULL hashes - i.e. it could not see the bug it was written to catch.

 2. **Macro contract for the escaping change** (committed `macros/wrap_string_with_quotes.sql` +
    `macros/cross_db_shim/maxcompute_shims.sql`, with dbt-core's own default macros read from the
    installed package). Rendered through Jinja with a minimal `dbt.string_literal` /
    `dbt.escape_single_quotes` stand-in for the MaxCompute and the SQL-standard default paths.

Scope statement, so nothing here is over-claimed: (1) proves the *predicate* of the test, not the
warehouse; (2) proves the *macro text*, not dbt's dispatch resolution and not any parser. The live
green/red evidence for the warehouse behaviour is the `integration_tests` run, reported separately.

Exit codes: 0 all checks passed | 1 a check actually failed | 2 blocked - a dependency
(jinja2, PyYAML or dbt-core's macro sources) is missing, so part of the contract could not
run at all. Blocked is never reported as a pass, and it exits 2 rather than 1 because it is
an environment gap, not a broken assertion.
"""
import hashlib
import json
import os
import re
import sqlite3
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TEST_SQL = os.path.join(REPO, "integration_tests", "tests", "assert_free_text_roundtrip.sql")
WRAP_SQL = os.path.join(REPO, "macros", "wrap_string_with_quotes.sql")
SHIM_SQL = os.path.join(REPO, "macros", "cross_db_shim", "maxcompute_shims.sql")
DBT_PROJECT = os.path.join(REPO, "dbt_project.yml")
README = os.path.join(REPO, "README.md")
REPORTS_YML = os.path.join(REPO, "integration_tests", "models", "reports", "reports.yml")
EXPOSURES_YML = os.path.join(REPO, "integration_tests", "models", "marts", "exposures.yml")

failures = []
checks = 0


def check(name, ok, detail=""):
    global checks
    checks += 1
    print(("CHECK-OK   " if ok else "CHECK-FAIL ") + name + ((" | " + detail) if detail else ""))
    if not ok:
        failures.append(name)


def read(path):
    with open(path, encoding="utf-8") as handle:
        return handle.read()


def jinja_tojson(obj):
    """Mirror of Jinja's tojson: json.dumps(sort_keys=True, ensure_ascii=True) plus html-safe."""
    return (json.dumps(obj, sort_keys=True, ensure_ascii=True)
            .replace("<", "\\u003c").replace(">", "\\u003e")
            .replace("&", "\\u0026").replace("'", "\\u0027"))


def md5_utf8(text):
    return hashlib.md5(text.encode("utf-8")).hexdigest()


# ---------------------------------------------------------------- fixtures -> expected constants
def fixture_values():
    import yaml
    reports = yaml.safe_load(read(REPORTS_YML))
    model = [m for m in reports["models"] if m["name"] == "report_1"][0]
    column = [c for c in model["columns"] if c["name"].strip() == "col"][0]
    exposures = yaml.safe_load(read(EXPOSURES_YML))["exposures"]
    exposure = [e for e in exposures if e["name"] == "exposure_1"][0]
    return {
        ("column", "report_1.col", "description"): column["description"],
        ("exposure", "exposure_1", "meta"): jinja_tojson(exposure["meta"]),
        ("exposure", "exposure_1", "owner_name"): exposure["owner"]["name"],
    }


def expected_rows_from_sql():
    """Parse the expected CTE: (resource_type, resource_name, value_field) -> expected_md5."""
    body = read(TEST_SQL)
    body = re.sub(r"\{#-.*?-#\}", "", body, flags=re.S)
    cte = body.split("with expected as", 1)[1].split("\n),", 1)[0]
    rows = {}
    for chunk in cte.split("union all"):
        tokens = re.findall(r"'([^']*)'", chunk)
        hexes = [t for t in tokens if re.fullmatch(r"[0-9a-f]{32}", t)]
        words = [t for t in tokens if t not in hexes]
        if len(words) >= 3 and len(hexes) == 1:
            rows[tuple(words[:3])] = hexes[0]
    return rows


def check_constants():
    try:
        fixtures = fixture_values()
    except ImportError as exc:
        return None, None, "PyYAML is unavailable: %s" % exc
    from_sql = expected_rows_from_sql()
    problems = []
    if len(from_sql) != 3:
        problems.append("expected CTE parsed %d rows, expected 3" % len(from_sql))
    for key, text in fixtures.items():
        want = md5_utf8(text)
        got = from_sql.get(key)
        if got is None:
            problems.append("expected row %s not found in the SQL" % (key,))
        elif got != want:
            problems.append("%s constant %s != value recomputed from fixtures %s" % (key, got, want))
    check("md5 constants in the test match the values recomputed from the fixtures", not problems,
          "3/3 rows agree")
    return fixtures, from_sql, None


# ---------------------------------------------------------------- (1) assertion truth table
def render_sql_for_sqlite():
    sql = read(TEST_SQL)
    sql = re.sub(r"\{#-.*?-#\}", "", sql, flags=re.S)
    sql = re.sub(r"\{\{\s*ref\('([^']+)'\)\s*\}\}", r"\1", sql)
    sql = re.sub(r"lower\(\{\{\s*dbt\.hash\('([^']+)'\)\s*\}\}\)", r"lower(md5(\1))", sql)
    if "{{" in sql:
        return None, "unsubstituted Jinja remains in the test SQL; the offline reproduction cannot cover it"
    return sql, None


def make_db(conn):
    conn.execute("create table stg_exposures (name text, owner_name text, meta text)")
    conn.execute("create table base_node_columns (node_unique_id text, name text, description text)")


def run_case(sql, exposure_rows, column_rows):
    conn = sqlite3.connect(":memory:")
    conn.create_function("md5", 1, lambda v: None if v is None else md5_utf8(v))
    make_db(conn)
    conn.executemany("insert into stg_exposures values (?,?,?)", exposure_rows)
    conn.executemany("insert into base_node_columns values (?,?,?)", column_rows)
    rows = [dict(zip(("resource_type", "resource_name", "value_field", "expected_md5",
                      "actual_rows", "non_null_stored_values", "matching_rows", "failure_reason"), r))
            for r in conn.execute(sql).fetchall()]
    conn.close()
    return rows


def check_truth_table(fixtures):
    sql, err = render_sql_for_sqlite()
    if err:
        check("test SQL renders offline", False, err)
        return
    desc = fixtures[("column", "report_1.col", "description")]
    meta = fixtures[("exposure", "exposure_1", "meta")]
    owner = fixtures[("exposure", "exposure_1", "owner_name")]
    good_col = [("model.dbt_project_evaluator_integration_tests.report_1", "col", desc)]

    # a) correct values: must return zero rows, otherwise the test just always fails
    rows = run_case(sql, [("exposure_1", owner, meta)], good_col)
    check("control: character-for-character equal values -> 0 failing rows", rows == [], str(rows)[:200])

    # b) missing rows: the INNER JOIN shape of this test passed silently here
    rows = run_case(sql, [], [])
    reasons = sorted(r["failure_reason"] for r in rows)
    check("negative control: missing rows fail as missing for all 3 keys",
          len(rows) == 3 and all(r.startswith("missing:") for r in reasons),
          "rows=%d %s" % (len(rows), reasons))

    # c) every stored value comes back NULL
    rows = run_case(sql, [("exposure_1", None, None)],
                    [("model.dbt_project_evaluator_integration_tests.report_1", "col", None)])
    reasons = sorted(r["failure_reason"] for r in rows)
    check("negative control: NULL stored values fail as null_stored_value",
          len(rows) == 3 and all(r.startswith("null_stored_value:") for r in reasons),
          "rows=%d %s" % (len(rows), reasons))

    # d) one expected key matched more than one actual row
    rows = run_case(sql, [("exposure_1", owner, meta), ("exposure_1", owner, meta)], good_col)
    bad = [r for r in rows if r["failure_reason"]]
    check("negative control: duplicate rows fail even though the values agree",
          len(bad) == 2 and all(r["failure_reason"].startswith("duplicate:") for r in bad),
          "rows=%d %s" % (len(bad), [r["failure_reason"] for r in bad]))

    # e) text rewritten by the warehouse: \b read back as a backspace
    mangled = desc.replace("\\backslash", "\x08ackslash")
    rows = run_case(sql, [("exposure_1", owner, meta)],
                    [("model.dbt_project_evaluator_integration_tests.report_1", "col", mangled)])
    bad = [r for r in rows if r["failure_reason"]]
    check("negative control: rewritten text fails as md5_mismatch",
          len(bad) == 1 and bad[0]["failure_reason"].startswith("md5_mismatch:")
          and bad[0]["value_field"] == "description",
          "rows=%d %s" % (len(bad), [(r["value_field"], r["failure_reason"]) for r in bad]))


# ---------------------------------------------------------------- (2) macro contract
def dbt_core_macro_module(fname):
    """Return the *whole* macro file from dbt-core's global project.

    The macro body is not extracted: the `{% ... -%}` / `{%- ... %}` whitespace trimming is part
    of the macro's meaning, and rendering a bare body would fold newlines into the literal that
    dbt never produces."""
    import dbt.include.global_project as gp  # type: ignore
    src = read(os.path.join(os.path.dirname(gp.__file__), "macros", "utils", fname))
    return src


def build_renderer():
    import jinja2
    env = jinja2.Environment(extensions=["jinja2.ext.do"])
    try:
        lit_src = dbt_core_macro_module("literal.sql")
        esc_src = dbt_core_macro_module("escape_single_quotes.sql")
    except (ImportError, OSError) as exc:
        return None, "cannot read dbt-core default__ macro sources (%s)" % exc
    shim_src = read(SHIM_SQL)
    if "maxcompute__escape_single_quotes" not in shim_src:
        return None, "the package shim does not define maxcompute__escape_single_quotes"

    lit_mod = env.from_string(lit_src).make_module()
    esc_mod = env.from_string(esc_src).make_module()
    shim_mod = env.from_string(shim_src).make_module()

    class Dbt(object):
        def __init__(self, adapter):
            self.adapter = adapter

        def string_literal(self, value):
            return lit_mod.default__string_literal(value)

        def escape_single_quotes(self, expression):
            if self.adapter == "maxcompute":
                return shim_mod.maxcompute__escape_single_quotes(expression)
            return esc_mod.default__escape_single_quotes(expression)

    class Dpe(object):
        def type_string_dpe(self):
            return "string"

    def render_wrap(value, adapter):
        globals_dict = {
            "dbt": Dbt(adapter),
            "dbt_project_evaluator": Dpe(),
            "return": lambda x: x,
            "tojson": lambda x: jinja_tojson(x),
        }
        module = env.from_string(read(WRAP_SQL)).make_module(globals_dict)
        return module.wrap_string_with_quotes(value)

    # Escape once on its own, so the double-escape comparison can be made explicit.
    def escape_only(expression, adapter):
        return (shim_mod.maxcompute__escape_single_quotes(expression)
                if adapter == "maxcompute" else esc_mod.default__escape_single_quotes(expression))

    return (render_wrap, escape_only), None


def decode_sql_standard(literal):
    """Read a SQL-standard literal back: strip the outer quotes, '' is one quote, a
    backslash is an ordinary character."""
    assert literal.startswith("'") and literal.endswith("'"), literal
    return literal[1:-1].replace("''", "'")


def decode_hive_style(literal, trace=None):
    """Read a MaxCompute (Hive-style) literal back, using the escape rules measured against a
    live project while developing this change (reported on the pull request):
      \\'      -> one quote       ; ''  -> concatenation of two literals, the quote disappears
      \\b      -> 0x08 backspace  ; \\\\ -> one backslash
      \\u0027  -> NOT decoded: the backslash is dropped, the text "u0027" is stored
    \\n, \\r, \\t and "any other \\x drops the backslash and keeps x" are extrapolated from
    those measured cases rather than measured one by one; the decoder implements them as
    described here.
    """
    assert literal.startswith("'") and literal.endswith("'"), literal
    body = literal[1:-1]
    out = []
    i = 0
    named = {"b": "\x08", "n": "\n", "r": "\r", "t": "\t", "\\": "\\", "'": "'", '"': '"'}
    while i < len(body):
        ch = body[i]
        if ch != "\\" or i + 1 >= len(body):
            if trace is not None and ch in ("'", "\x08"):
                trace.append(ch)
            out.append(ch)
            i += 1
            continue
        nxt = body[i + 1]
        if nxt == "u":
# measured: \uXXXX is not decoded - the backslash is dropped and uXXXX is stored
            if trace is not None:
                trace.append("dropped-backslash-u")
            out.append("u")
            i += 2
            continue
        if nxt in named:
            if trace is not None:
                trace.append("escape-%s" % nxt)
            out.append(named[nxt])
            i += 2
            continue
        if trace is not None:
            trace.append("unknown-escape-%s" % nxt)
        out.append(nxt)
        i += 2
    return "".join(out)


def check_macro_contract():
    """Run the macro half; return None, or the reason the environment blocked it.

    Missing dbt-core macro sources is a *blocked* state, not a failed assertion: the code under
    test is fine, the runner simply cannot reach the reference macros. Review feedback on bba8422
    asked for this to match the documented exit classification before the script goes into CI.
    """
    built, err = build_renderer()
    if err:
        return err
    render_wrap, escape_only = built

    def lit(value, adapter):
        # Only whitespace around the literal is normalised: it lands between items of
        # the SELECT list and carries no SQL meaning. Nothing inside the quotes is
        # that difference is exactly what this contract is about.
        return render_wrap(value, adapter).strip()

    tojson_text = jinja_tojson({"note": "it's a caf\u00e9", "path": "C:\\temp"})
    cases = [
        ("apostrophe", "tom cruise's report"),
        ("backslash", "col with \\backslash and 中文"),
        ("combined", "col with \\backslash and 'quote' 中文"),
        ("tojson_text", tojson_text),
        ("empty", ""),
        ("numeric", 5),
        ("boolean", True),
        ("typed_null", None),
    ]

    # Hand-typed literal shapes: only the cases a human needs to read as the spec.
    expect_mc = {
        "apostrophe": r"'tom cruise\'s report'",
        "backslash": r"'col with \\backslash and 中文'",
        "combined": r"'col with \\backslash and \'quote\' 中文'",
        "empty": "''",
        "numeric": "'5'",
        "boolean": "'True'",
        "typed_null": "cast(NULL as string)",
    }
    expect_default = {
        "apostrophe": "'tom cruise''s report'",
        "backslash": "'col with \\backslash and 中文'",
        "combined": "'col with \\backslash and ''quote'' 中文'",
        "empty": "''",
        "numeric": "'5'",
        "boolean": "'True'",
        "typed_null": "cast(NULL as string)",
    }
    # The tojson case is deliberately not hand-typed: transcribing that many backslashes by
    # hand is the very failure class under test. It is covered by the reversibility check.

    for adapter, expect in (("maxcompute", expect_mc), ("default", expect_default)):
        for label, value in cases:
            if label not in expect:
                continue
            got = lit(value, adapter)
            check("%s/%s literal shape" % (adapter, label), got == expect[label],
                  "got=%r want=%r" % (got, expect[label]) if got != expect[label] else "")

    # Semantic check: decoding the literal with the dialect's own reading rules must return
    for label, value in cases:
        if value is None:
            check("typed_null does not produce a literal in either dialect",
                  lit(value, "maxcompute") == "cast(NULL as string)", "")
            continue
        text = value if isinstance(value, str) else str(value)
        for adapter, decode in (("maxcompute", decode_hive_style), ("default", decode_sql_standard)):
            got = lit(text, adapter)
            try:
                back = decode(got)
            except AssertionError as exc:
                check("%s/%s reversible" % (adapter, label), False, "not a quoted literal: %r" % (exc,))
                continue
            check("%s/%s reversible (decoded == manifest value)" % (adapter, label), back == text,
                  "" if back == text else "back=%r want=%r" % (back, text))

    # the manifest value character for character.
    raw = "'" + "col with \\backslash and 中文" + "'"
    trace = []
    mangled = decode_hive_style(raw, trace)
    check("undoubled backslash is rewritten by the server reading (defect shape reproduced)",
          mangled != "col with \\backslash and 中文" and mangled.startswith("col with \x08"),
          "mangled=%r trace=%s" % (mangled, trace))

    # Call sites that still pre-escape get escaped a second time at the choke point; that
    single = lit("a'b", "maxcompute")
    double = lit(escape_only("a'b", "maxcompute"), "maxcompute")
    check("a pre-escaped call site escapes twice (must differ from single escaping)",
          double != single and double.count("\\\\") > single.count("\\\\"),
          "single=%r double=%r" % (single, double))
    check("double escaping decodes to something other than the original",
          decode_hive_style(double) != "a'b", "restored=%r" % decode_hive_style(double))

    proj = read(DBT_PROJECT)
    readme = read(README)
    check("dbt_project.yml declares the dispatch search_order the macros rely on",
          "search_order: ['dbt_project_evaluator', 'dbt']" in proj, "")
    check("README tells root projects to configure the same dispatch search_order",
          "search_order: ['dbt_project_evaluator', 'dbt']" in readme, "")

    return None


def main():
    try:
        import jinja2  # noqa: F401
    except ImportError as exc:
        print("CONTRACT: BLOCKED - jinja2 unavailable (%s); no check ran, this is not a pass" % exc)
        return 2
    fixtures, _, err = check_constants()
    if fixtures is None:
        print("CONTRACT: BLOCKED - %s" % err)
        return 2
    check_truth_table(fixtures)
    blocked = check_macro_contract()
    print("CONTRACT: checks=%d failures=%d" % (checks, len(failures)))
    if blocked:
        print("CONTRACT: BLOCKED - %s; the macro half never ran, so this is not a pass (exit 2)" % blocked)
        return 2
    if failures:
        for name in failures:
            print("  FAILED:", name)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
