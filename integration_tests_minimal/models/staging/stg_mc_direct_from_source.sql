-- VIOLATION (dag/fct_direct_join_to_source): joins a model and a source
-- directly, and is NOT listed in the exceptions seed.

select
    base_orders.order_id

from {{ ref('base_mc_orders') }} as base_orders

inner join {{ source('mc_source', 'raw_orders') }} as raw_orders
    on base_orders.order_id = raw_orders.order_id
