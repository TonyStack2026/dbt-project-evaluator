-- VIOLATION (dag/fct_hard_coded_references): the join target is written as a
-- literal schema.table instead of being declared as a source or ref.
-- Ephemeral, so the fake relation is never sent to the warehouse.

select
    raw_orders.order_id

from {{ ref('mc_raw_orders') }} as raw_orders

inner join fixture_schema.some_external_table as some_external_table
    on raw_orders.order_id = some_external_table.order_id
