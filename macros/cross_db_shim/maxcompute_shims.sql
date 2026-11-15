{#- MaxCompute string literals use Hive-style backslash escaping, which differs from the
    SQL standard on two counts:
      1) a single quote has to be written as \' ; two adjacent '' are treated as concatenation
         of two literals, so the quote simply disappears from the stored value;
      2) a backslash introduces an escape sequence, so a value containing \b, the \u0027 that
         `tojson` emits for an apostrophe, or a Windows path like C:\temp has to have its
         backslashes doubled first - otherwise the server rewrites the text silently and no
         error is raised.

    The MaxCompute adapter ships maxcompute__escape_single_quotes for (1) but not (2). This
    package overrides the same macro with both steps, which is reached through
    adapter.dispatch because the root project declares
    `search_order: ['dbt_project_evaluator', 'dbt']` (see README). Once the adapter escapes
    backslashes as well, this override stays semantically identical and can be dropped.

    Paired constraint: escaping happens exactly once, in wrap_string_with_quotes(). Call sites
    must not pre-apply dbt.escape_single_quotes() or double backslashes by hand, or values get
    escaped twice. Regression coverage: integration_tests/tests/assert_free_text_roundtrip.sql.
 -#}
{% macro maxcompute__escape_single_quotes(expression) -%}
{{ expression | replace("\\", "\\\\") | replace("'", "\\'") }}
{%- endmacro %}
