with direct_model_relationships as (
    select
        *
    from {{ ref('int_all_dag_relationships') }}
    where child_resource_type = 'model'
    and distance = 1
    and not parent_is_excluded
    and not child_is_excluded
),

model_and_source_joined as (
    select
        child,
        case
            when (
                sum(case when parent_resource_type = 'model' then 1 else 0 end) > 0
                and sum(case when parent_resource_type = 'source' then 1 else 0 end) > 0
            )
            then true
            else false
        end as keep_row
    from (
        select *
        from {{ ref('int_all_dag_relationships') }}
        where child_resource_type = 'model'
        and distance = 1
        and not parent_is_excluded
        and not child_is_excluded
    ) parents
    group by child
),

-- filter_exceptions() appends an unqualified column predicate ("and <column> not like ...").
-- Applied straight after a join of two relations that both expose `child`, MaxCompute rejects it:
--   ODPS-0130071:[53,21] Semantic analysis exception - child is ambiguous, can be both
--   direct_model_relationships.child or model_and_source_joined.child
-- Wrapping the join in `final` first matches how every other rule model in this package already
-- applies the exception filter (one relation, so the column can never be ambiguous).
final as (
    select
        direct_model_relationships.parent,
        direct_model_relationships.parent_resource_type,
        direct_model_relationships.child,
        direct_model_relationships.child_resource_type,
        direct_model_relationships.distance
    from direct_model_relationships
    inner join model_and_source_joined
        on direct_model_relationships.child = model_and_source_joined.child
    where model_and_source_joined.keep_row
)

select * from final
where 1=1
{{ filter_exceptions() }}
order by child
