# 0018. Backfill vintages, derived-period completeness, and pack-owned rows

- Status: accepted
- Date: 2026-11-03

## Context

The `regional_economy` pack reads public FRED CSV files. These files give values but no publication dates. Under ADR 0010, every backfilled value then gets today's fetch time as `observed_at`, so a replay at a past date sees no data, and a past question cannot resolve. A second problem: `aggregate_by_period` treated a quarter as complete when its time had passed, even if its last month was not yet published. Last, scenarios and model versions had no `pack` column, so a pack could not own them.

## Decision

- **Publication lag.** A source spec can set `publication_lag` (an ISO 8601 duration). A row without a publication column then gets `observed_at = min(effective_at + lag, fetch time)`, marked as assumed.
  - The refresh step gives a revision of a stored record the real fetch time, so revisions stay visible as new vintages.
  - The `since` filter keeps assumed rows, because an assumed time is not a real vintage.
- **Completeness.** For `sum` and `mean`, `aggregate_by_period` makes a period only when the input has a value in the period's last input-cadence step. `count` stays time-based, because events can correctly be absent.
- **Constant attributes.** A spec can set `constant_attributes` (for example `{"place": "Ingham County"}`). With `entity_attributes`, this lets a series name its entity, so the domain and canonical-series rules apply to series too.
- **Pack columns.** `scenarios` and `model_versions` get a `pack` column. A pack folder can include `models.json`.
- **Change-point history.** The changepoints step uses at most `max_points` values (config `changepoint_detector`, default 240).

## Consequences

- The publication lags in the pack are approximate.
- A backtest or replay on backfilled data assumes that each value was known at `effective_at + lag`.
