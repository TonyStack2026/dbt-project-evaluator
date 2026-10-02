# Minimal MaxCompute suite

A small, fixed DAG whose models are chosen so that each pinned rule has exactly one
deliberate reason to fire, one deliberate reason *not* to fire, and one exemption that is
supposed to silence a real hit. It exists because the big `integration_tests` project covers
many rules at once and is slow to run: this one is the fast, readable regression entry for
"did the rules still measure what they claim to measure".

Run it with the shared entrypoint (see [docs/maxcompute-integration-tests.md](../docs/maxcompute-integration-tests.md)):

```bash
./scripts/run-maxcompute-integration-tests.sh integration_tests_minimal
```

## What is in the graph

| Resource | Shape | Intended outcome |
| --- | --- | --- |
| `mc_raw_orders` (seed) | real table | input for the healthy chain |
| `base_mc_orders` → `stg_mc_orders` → `int_mc_orders_agg` → `fct_mc_orders` | documented, tested, layered | must not be reported by the pinned rules |
| `staging/stg_mc_orphan.sql` | no upstream resource at all | `fct_root_models` reports it |
| `staging/stg_mc_direct_from_source.sql` | joins a model *and* a source | `fct_direct_join_to_source` reports it |
| `staging/stg_mc_exempted_direct_source.sql` | same shape, listed in `seeds/dbt_project_evaluator_exceptions.csv` | must stop being reported (the exemption path) |
| `staging/stg_mc_hard_coded.sql` | joins a literal `schema.table` | `fct_hard_coded_references` reports it |
| `marts/orders_report.sql` | no accepted marts prefix | `fct_model_naming_conventions` reports it |
| `marts/fct_mc_undocumented.sql` | no description | `fct_undocumented_models` reports it |
| `mc_source.raw_orders` / `mc_source.unused_orders` | declared sources | the unused one must be reported by `fct_unused_sources` |

Fixture models that would only read a fake relation are `ephemeral` (the project default), so
they never reach the warehouse; the healthy chain and the naming/documentation violations are
real views over the seed, so the suite executes real SQL end to end.

## How expectations are written

`tests/expect_*.sql` are singular tests: each `UNION ALL` branch returns a row only when an
expectation is **not** met, and the row carries the expectation text. A passing suite therefore
means every listed rule row was produced, and that nothing in the healthy chain was reported.
`tests/expect_healthy_models_are_not_flagged.sql` is the control half — without it a fixture
that silently stopped triggering anything would also look green.

Exemptions are matched with `not like`, so `_` behaves as a single-character wildcard; resource
names here are distinct enough not to collide with each other.
