-- Same shape as stg_mc_direct_from_source, but seeds/dbt_project_evaluator_exceptions.csv
-- exempts it. The suite asserts the rule stops reporting it, which is what
-- proves the exemption path works on the target warehouse.

select
    base_orders.order_id

from {{ ref('base_mc_orders') }} as base_orders

inner join {{ source('mc_source', 'raw_orders') }} as raw_orders
    on base_orders.order_id = raw_orders.order_id
