-- healthy layer 3

select
    customer_id,
    count(*) as order_count,
    sum(order_total) as order_total

from {{ ref('stg_mc_orders') }}

group by customer_id
