-- A1/A2 (dag family): the minimal DAG must produce exactly these rule rows.
-- Each branch returns one row when an expectation is NOT met, so a passing test
-- means the warehouse really evaluated the rules against this fixture.

with root_models as (
    select child from {{ ref('fct_root_models') }}
),

direct_join_to_source as (
    select child from {{ ref('fct_direct_join_to_source') }}
),

unused_sources as (
    select parent from {{ ref('fct_unused_sources') }}
),

hard_coded_references as (
    select model from {{ ref('fct_hard_coded_references') }}
)

select expectation
from (
    select 'fct_root_models must report stg_mc_orphan' as expectation,
           count(*) as matched
    from root_models
    where child = 'stg_mc_orphan'
) root_orphan
where matched = 0

union all

select expectation
from (
    select 'fct_direct_join_to_source must report stg_mc_direct_from_source' as expectation,
           count(*) as matched
    from direct_join_to_source
    where child = 'stg_mc_direct_from_source'
) direct_source
where matched = 0

union all

select expectation
from (
    select 'fct_unused_sources must report mc_source.unused_orders' as expectation,
           count(*) as matched
    from unused_sources
    where parent = 'mc_source.unused_orders'
) unused_source
where matched = 0

union all

select expectation
from (
    select 'fct_hard_coded_references must report stg_mc_hard_coded' as expectation,
           count(*) as matched
    from hard_coded_references
    where model = 'stg_mc_hard_coded'
) hard_coded
where matched = 0
