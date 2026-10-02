-- A2 (empty project): with nothing to evaluate the rules must produce zero
-- findings. A row here means the package invented a finding, or crashed into a
-- division that has no denominator.

with undocumented_models as (
    select resource_name from {{ ref('fct_undocumented_models') }}
),

root_models as (
    select child from {{ ref('fct_root_models') }}
),

unused_sources as (
    select parent from {{ ref('fct_unused_sources') }}
),

naming_conventions as (
    select resource_name from {{ ref('fct_model_naming_conventions') }}
),

hard_coded_references as (
    select model from {{ ref('fct_hard_coded_references') }}
)

select expectation
from (
    select 'fct_undocumented_models must be empty on an empty project' as expectation,
           count(*) as rows_found
    from undocumented_models
) undocumented
where rows_found > 0

union all

select expectation
from (
    select 'fct_root_models must be empty on an empty project' as expectation,
           count(*) as rows_found
    from root_models
) roots
where rows_found > 0

union all

select expectation
from (
    select 'fct_unused_sources must be empty on an empty project' as expectation,
           count(*) as rows_found
    from unused_sources
) unused
where rows_found > 0

union all

select expectation
from (
    select 'fct_model_naming_conventions must be empty on an empty project' as expectation,
           count(*) as rows_found
    from naming_conventions
) naming
where rows_found > 0

union all

select expectation
from (
    select 'fct_hard_coded_references must be empty on an empty project' as expectation,
           count(*) as rows_found
    from hard_coded_references) hard_coded
where rows_found > 0
