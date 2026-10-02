-- A1 (the control half): the documented/tested/layered chain must not appear in
-- any of the pinned rule outputs. Without this direction a fixture that simply
-- never triggers anything would look like a pass.

with root_models as (
    select child from {{ ref('fct_root_models') }}
),

naming_conventions as (
    select resource_name from {{ ref('fct_model_naming_conventions') }}
),

undocumented_models as (
    select resource_name from {{ ref('fct_undocumented_models') }}
),

direct_join_to_source as (
    select child from {{ ref('fct_direct_join_to_source') }}
)

select expectation
from (
    select 'the healthy chain must not be reported by fct_root_models' as expectation,
           count(*) as matched
    from root_models
    where child in ('base_mc_orders', 'stg_mc_orders', 'int_mc_orders_agg', 'fct_mc_orders')
) healthy_roots
where matched > 0

union all

select expectation
from (
    select 'the healthy chain must not be reported by fct_model_naming_conventions' as expectation,
           count(*) as matched
    from naming_conventions
    where resource_name in ('base_mc_orders', 'stg_mc_orders', 'int_mc_orders_agg', 'fct_mc_orders')
) healthy_names
where matched > 0

union all

select expectation
from (
    select 'documented fixture models must not be reported by fct_undocumented_models' as expectation,
           count(*) as matched
    from undocumented_models
    where resource_name in ('base_mc_orders', 'stg_mc_orders', 'int_mc_orders_agg',
                            'fct_mc_orders', 'orders_report', 'stg_mc_orphan',
                            'stg_mc_direct_from_source', 'stg_mc_hard_coded')
) healthy_docs
where matched > 0

union all

select expectation
from (
    select 'fct_direct_join_to_source must not report the exempted model' as expectation,
           count(*) as matched
    from direct_join_to_source
    where child = 'stg_mc_exempted_direct_source'
) exempted
where matched > 0
