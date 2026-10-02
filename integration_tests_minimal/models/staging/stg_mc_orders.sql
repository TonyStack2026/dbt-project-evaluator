-- healthy layer 2

select
    order_id,
    customer_id,
    order_total

from {{ ref('base_mc_orders') }}

where order_id is not null
