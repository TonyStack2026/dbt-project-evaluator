-- VIOLATION (structure/fct_model_naming_conventions): sits in the marts folder
-- but carries none of the accepted marts prefixes (fct_ / dim_).

select
    order_id,
    order_total

from {{ ref('mc_raw_orders') }}
