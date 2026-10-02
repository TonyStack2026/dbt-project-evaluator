-- VIOLATION (documentation/fct_undocumented_models): deliberately described in
-- models/healthy.yml? no - it is left out of the yml on purpose.

select
    order_id

from {{ ref('mc_raw_orders') }}
