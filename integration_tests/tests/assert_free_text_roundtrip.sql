{#- Round-trip assertion: free text that this package writes into the graph tables must come
    back character-for-character equal to the value in the manifest.

    The check is driven from the expected side with a LEFT JOIN, and four states are failures:
    no row for an expected key (missing), more than one row (duplicate), a NULL stored value
    (null_stored_value), or a stored md5 that is not the manifest md5 (md5_mismatch).
    A plain `expected INNER JOIN actual ... WHERE expected_md5 <> actual_md5` cannot do this:
    a missing row disappears in the join and a NULL hash makes the comparison UNKNOWN, so both
    produce zero failing rows - the test would pass on a graph table that never got the text at
    all. Review on the previous head reproduced exactly that truth table; this version is built
    so that every one of those states fails, and scripts/check-free-text-contract.py keeps the
    proof running offline.

    Why the expected side is md5 hex constants rather than SQL string literals: the expected
    value must not be produced by the escaping code under test. If it were, a broken escape
    would corrupt both sides and the assertion could never fail - which is exactly how this
    defect stayed invisible: the suites assert rule hit counts, and nothing compared the text.

    Expected values (UTF-8 bytes -> md5 hex). dbt.hash() keeps this portable; on MaxCompute it
    dispatches to md5(), which returns lowercase hex and matched the offline values in a live
    run against a three-tier project:
      1) column.description of report_1.col = col me maybe \backslash 'quote' 中文
      2) node.meta of exposure_1, stored as its tojson text
         {"note": "it\u0027s a caf\u00e9", "path": "C:\\temp"}
      3) owner.name of exposure_1 = dave's davey (already in the fixtures, untouched here)
    Fixtures: integration_tests/models/reports/reports.yml (1),
    integration_tests/models/marts/exposures.yml (2, 3).
    scripts/check-free-text-contract.py recomputes these three constants from the YAML fixtures
    and fails if this file drifts away from them.

    Why staging relations (stg_exposures / base_node_columns) rather than int_all_graph_resources:
    on `main` the model-side branch stg_nodes fails for a reason unrelated to escaping
    (sql_complexity reaches the server as DOUBLE while the column is FLOAT, ODPS-0130071), so
    everything downstream is skipped - and a skipped assertion must not be counted as a pass.
    Move these keys onto the mart once that cast is on the trunk.
-#}

with expected as (

    select 'column' as resource_type, 'report_1.col' as resource_name, 'description' as value_field,
           '4f6218c1adf3089a2dfd2d5592dfa5e0' as expected_md5
    union all
    select 'exposure', 'exposure_1', 'meta',
           'f44709c9c8b753db2e8a835c7695d60c'
    union all
    select 'exposure', 'exposure_1', 'owner_name',
           '995b9b6be2df77e2c97ab58b9474de05'

),

actual as (

    select
        'exposure' as resource_type,
        name as resource_name,
        'owner_name' as value_field,
        lower({{ dbt.hash('owner_name') }}) as actual_md5,
        owner_name as stored_value
    from {{ ref('stg_exposures') }}

    union all

    select
        'exposure' as resource_type,
        name as resource_name,
        'meta' as value_field,
        lower({{ dbt.hash('meta') }}) as actual_md5,
        meta as stored_value
    from {{ ref('stg_exposures') }}

    union all

    select
        'column' as resource_type,
        'report_1.col' as resource_name,
        'description' as value_field,
        lower({{ dbt.hash('description') }}) as actual_md5,
        description as stored_value
    from {{ ref('base_node_columns') }}
    where node_unique_id like '%.report_1'
      and name = 'col'

),

per_key as (

    select
        expected.resource_type,
        expected.resource_name,
        expected.value_field,
        expected.expected_md5,
        count(actual.value_field) as actual_rows,
        count(actual.stored_value) as non_null_stored_values,
        sum(case when actual.actual_md5 = expected.expected_md5 then 1 else 0 end) as matching_rows
    from expected
    left join actual
        on expected.resource_type = actual.resource_type
       and expected.resource_name = actual.resource_name
       and expected.value_field = actual.value_field
    group by
        expected.resource_type,
        expected.resource_name,
        expected.value_field,
        expected.expected_md5

),

verdict as (

    select
        per_key.*,
        case
            when per_key.actual_rows = 0 then 'missing: no row returned for an expected key'
            when per_key.actual_rows > 1 then 'duplicate: more than one row for one expected key'
            when per_key.non_null_stored_values = 0 then 'null_stored_value: the column came back NULL'
            when per_key.matching_rows <> 1 then 'md5_mismatch: stored text differs from the manifest text'
            else null
        end as failure_reason
    from per_key

)

select
    resource_type,
    resource_name,
    value_field,
    expected_md5,
    actual_rows,
    non_null_stored_values,
    matching_rows,
    failure_reason
from verdict
where failure_reason is not null
