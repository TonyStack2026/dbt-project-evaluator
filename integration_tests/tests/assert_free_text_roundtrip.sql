{#- Round-trip assertion: free text that this package writes into the graph tables must come
    back character-for-character equal to the value in the manifest.

    Why the expected side is md5 hex constants rather than SQL string literals: the expected
    value must not be produced by the escaping code under test. If it were, a broken escape
    would corrupt both sides and the assertion could never fail - which is exactly how this
    defect stayed invisible: the integration suites assert rule hit counts, and nothing
    compared the stored text.

    Expected values (UTF-8 bytes -> md5 hex). dbt.hash() keeps this portable; on MaxCompute it
    dispatches to md5(), which returns lowercase hex and matched the offline values in a live
    run against a three-tier project.
      1) column.description of report_1.col = col me maybe \backslash 'quote' 中文
         -> 4f6218c1adf3089a2dfd2d5592dfa5e0
      2) node.meta of exposure_1, stored as its tojson text
         {"note": "it\u0027s a caf\u00e9", "path": "C:\\temp"}
         (Jinja tojson = json.dumps(sort_keys=True, ensure_ascii=True), with < > & ' escaped)
         -> f44709c9c8b753db2e8a835c7695d60c
      3) owner.name of exposure_1 = dave's davey (already in the fixtures, untouched here)
         -> 995b9b6be2df77e2c97ab58b9474de05
    Fixtures: integration_tests/models/reports/reports.yml (1),
    integration_tests/models/marts/exposures.yml (2, 3).

    Why the test reads staging relations (stg_exposures / base_node_columns) instead of
    int_all_graph_resources: on this baseline the model-side branch stg_nodes errors out for a
    reason unrelated to escaping (the sql_complexity literal is DOUBLE while the column is
    FLOAT, ODPS-0130071), so anything downstream of it would be skipped here and a skipped
    assertion is not a passing one. Move these three rows onto the mart once that cast lands.
-#}

with expected as (

    select 'column' as resource_type, 'report_1.col' as resource_name, 'description' as field,
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
        'owner_name' as field,
        lower({{ dbt.hash('owner_name') }}) as actual_md5,
        owner_name as stored_value
    from {{ ref('stg_exposures') }}

    union all

    select
        'exposure' as resource_type,
        name as resource_name,
        'meta' as field,
        lower({{ dbt.hash('meta') }}) as actual_md5,
        meta as stored_value
    from {{ ref('stg_exposures') }}

    union all

    select
        'column' as resource_type,
        'report_1.col' as resource_name,
        'description' as field,
        lower({{ dbt.hash('description') }}) as actual_md5,
        description as stored_value
    from {{ ref('base_node_columns') }}
    where node_unique_id like '%.report_1'
      and name = 'col'

)

select
    expected.resource_type,
    expected.resource_name,
    expected.field,
    expected.expected_md5,
    actual.actual_md5,
    actual.stored_value
from expected
inner join actual
    on expected.resource_type = actual.resource_type
   and expected.resource_name = actual.resource_name
   and expected.field = actual.field
where expected.expected_md5 <> actual.actual_md5
