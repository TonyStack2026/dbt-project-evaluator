-- healthy layer 4: the reference model the rules must NOT report

select
    customer_id,
    order_count,
    order_total

from {{ ref('int_mc_orders_agg') }}
