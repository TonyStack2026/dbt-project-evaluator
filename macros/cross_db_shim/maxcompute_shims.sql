{#
    **what?** Declares the floating point column type this package uses on MaxCompute.
    **why?** The package creates the graph staging models with dbt.type_float() and
             then inserts values taken from the dbt manifest. MaxCompute types a
             floating point literal as DOUBLE and refuses the implicit
             DOUBLE -> FLOAT conversion ("Implicit conversion is not applied because
             of potential data loss"), so stg_nodes errors out and every rule
             downstream of it is skipped. Declaring the column DOUBLE keeps the
             value the manifest already computed instead of squeezing it into FLOAT.
    **when?** Resolved through the dbt dispatch search order, so it applies only when
             the adapter is maxcompute and the consumer project has the dispatch
             block documented in the README. No other adapter reads this file.
#}

{%- macro maxcompute__type_float() -%}
    double
{%- endmacro -%}
