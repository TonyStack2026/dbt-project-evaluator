select * from (
    select
            direct_model_relationships.parent,
            direct_model_relationships.parent_resource_type,
            direct_model_relationships.child,
            direct_model_relationships.child_resource_type,
            direct_model_relationships.distance
    from
       (select
            *
        from {{ ref('int_all_dag_relationships') }}
        where child_resource_type = 'model'
        and distance = 1
        and not parent_is_excluded
        and not child_is_excluded
       ) as direct_model_relationships
    inner join
       (select
            child,
            case
                when (
                    sum(case when parent_resource_type = 'model' then 1 else 0 end) > 0
                    and sum(case when parent_resource_type = 'source' then 1 else 0 end) > 0
                )
                then true
                else false
            end as keep_row
        from
        (select *
         from {{ ref('int_all_dag_relationships') }}
         where child_resource_type = 'model'
         and distance = 1
         and not parent_is_excluded
         and not child_is_excluded
        ) as parents_of_child
        group by child
       ) as model_and_source_joined
    on direct_model_relationships.child = model_and_source_joined.child
    where model_and_source_joined.keep_row
) as final
-- filter_exceptions() appends an unqualified predicate ("and <column> not like ..."). Kept on the
-- join above, MaxCompute rejects it when the exempted column exists on both sides of the join:
--   ODPS-0130071:[53,21] Semantic analysis exception - child is ambiguous, can be both
--   direct_model_relationships.child or model_and_source_joined.child
-- Collapsing to one relation first matches how every other rule model in this package applies the
-- exception filter. The relation keeps its original derived-table shape: naming these as CTEs
-- instead makes MaxCompute report "recursive function call is not supported, cycle is
-- direct_model_relationships->int_all_dag_relationships->...->direct_model_relationships", because
-- views are inlined and the package's own upstream views use the same identifiers.
where 1=1
{{ filter_exceptions() }}
order by final.child
