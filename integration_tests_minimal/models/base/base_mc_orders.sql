-- healthy layer 1: one step away from the seed, documented and tested

select
    order_id,
    customer_id,
    order_total

from {{ ref('mc_raw_orders') }}
