# 0016. Resolution logic, stale forecasts, and the shared batch_context row

- Status: accepted
- Date: 2026-11-03

## Context

The prompt names `loop_threshold_crossed` and `loop_resolvable`, but does not say when a "false" outcome is known, how late data affects resolution, or how to measure a "move past the threshold" for a monthly series.

## Decision

- `loop_condition_status` is the single place that evaluates a series or events condition. A window is `[from, to)`.
  - For `end_of_window` and `mean_in_window`, the outcome is known when the window has ended and an observation exists in the window's last cadence period.
  - For `any_in_window` and `count>=`, a true outcome is known as soon as the data meets the condition.
  - For `count<=`, a false outcome is known as soon as the count exceeds the value.
- `loop_resolvable` lists live questions that are crossed or determined, or whose deadline has passed. When the outcome is not known (a manual condition, or incomplete data), the act step opens a `needs_resolution` work item. It does not guess.
- `loop_stale_forecast` compares a cited signal's latest value with its value as known at the forecast's `made_at`. The threshold is a share of the trailing range. The trailing values are those within `trailing_days`, or the latest `min_points` values if those are more. Without `min_points`, a monthly series has one point in 30 days, its range is 0, and it never becomes stale.
- `batch_context` is one row for the whole database, as the prompt says. A run or a backtest holds that row's lock until its transaction ends. Batch runs execute one at a time (the Oban queue limit is 1). A backtest and a batch run wait for each other. Tests that write the row run serially.

## Consequences

A question with late data waits in `needs_resolution` with the reason `awaiting_data`, and it resolves on the first run after the data arrives. To run backtests concurrently with the batch, change `batch_context` to a session setting. That change would also need a new ADR.
