-- A2 (structure + documentation families): one expected row per deliberate
-- violation, and the graph metadata that the rules are built from.

with naming_conventions as (
    select resource_name from {{ ref('fct_model_naming_conventions') }}
),

undocumented_models as (
    select resource_name from {{ ref('fct_undocumented_models') }}
),

graph_resources as (
    select resource_name, materialized, model_type, resource_type, is_described
    from {{ ref('int_all_graph_resources') }}
)

select expectation
from (
    select 'fct_model_naming_conventions must report orders_report' as expectation,
           count(*) as matched
    from naming_conventions
    where resource_name = 'orders_report'
) naming
where matched = 0

union all

select expectation
from (
    select 'fct_undocumented_models must report fct_mc_undocumented' as expectation,
           count(*) as matched
    from undocumented_models
    where resource_name = 'fct_mc_undocumented'
) undocumented
where matched = 0

union all

-- graph/metadata: the fixture's materializations and layer detection have to
-- survive what the adapter records, otherwise every rule below is measuring
-- an empty graph
select expectation
from (
    select 'int_all_graph_resources must record fct_mc_orders as a view mart' as expectation,
           count(*) as matched
    from graph_resources
    where resource_name = 'fct_mc_orders'
      and materialized = 'view'
      and model_type = 'marts'
      and resource_type = 'model'
) graph_view
where matched = 0

union all

select expectation
from (
    select 'int_all_graph_resources must record base_mc_orders as documented' as expectation,
           count(*) as matched
    from graph_resources
    where resource_name = 'base_mc_orders'
      and model_type = 'base'
      and is_described
) graph_described
where matched = 0

union all

select expectation
from (
    select 'int_all_graph_resources must record the fixture sources' as expectation,
           count(*) as matched
    from graph_resources
    where resource_type = 'source'
      and resource_name in ('mc_source.raw_orders', 'mc_source.unused_orders')
) graph_sources
where matched < 2
