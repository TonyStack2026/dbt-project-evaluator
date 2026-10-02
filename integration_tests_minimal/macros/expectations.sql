{#
    Expectation tests for the minimal suite.

    Every rule assertion is expressed as a real SQL query against the package's
    own fct_* / int_* relations, so a pass means the warehouse produced the
    expected rule rows, and a failure names the rule and the resource.
#}

{% test rule_hits(model, key_column, key_value) %}

select 1 as missing_expected_hit
from (
    select count(*) as matched_rows
    from {{ model }}
    where {{ key_column }} = '{{ key_value }}'
) expected
where expected.matched_rows = 0

{% endtest %}

{% test rule_does_not_hit(model, key_column, key_value) %}

select {{ key_column }} as unexpected_hit
from {{ model }}
where {{ key_column }} = '{{ key_value }}'

{% endtest %}

{% test graph_value_is(model, key_column, key_value, value_column, expected_value) %}

select actual_value, recorded_resource
from (
    select coalesce(cast({{ value_column }} as {{ dbt.type_string() }}), '<null>') as actual_value,
           {{ key_column }} as recorded_resource
    from {{ model }}
    where {{ key_column }} = '{{ key_value }}'
) recorded
where recorded.actual_value <> '{{ expected_value }}'

{% endtest %}
