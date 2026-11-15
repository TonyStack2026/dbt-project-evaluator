{% macro wrap_string_with_quotes(str) %}
  {% if str is none %}
    {{ return('cast(NULL as ' ~ dbt_project_evaluator.type_string_dpe() ~ ')') }}
  {% else %}
    {#- This is the only place where free text becomes a SQL literal (every graph value goes
        through here, and dbt.string_literal is not called anywhere else in the package).
        Escaping happens exactly once, at this choke point, so call sites must pass the raw
        manifest value: pre-applying dbt.escape_single_quotes() or doubling backslashes by
        hand would escape the value twice. Dialect differences are handled by the dispatch
        behind dbt.escape_single_quotes(); see macros/cross_db_shim/maxcompute_shims.sql. -#}
    {{ dbt.string_literal(dbt.escape_single_quotes(str)) }}
  {% endif %}
{% endmacro %}
