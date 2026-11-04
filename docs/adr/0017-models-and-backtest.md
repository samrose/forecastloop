# 0017. Model contract and backtest method

- Status: accepted
- Date: 2026-11-03

## Context

The prompt gives `forecast(model_version, question, as_of)` and a backtest task. It does not say how a model reports the signals it used, when the backtest forecasts, or how it scores without writing to the ledger.

## Decision

- `forecast/3` returns `{:ok, probability, rationale, cited_signal_ids}` or `{:error, reason}`. `{:error, :not_applicable}` means the model does not handle this kind of question. The act step then writes nothing, so a rerun changes nothing.
- A model version names its module in `model_module`. Only registered modules run: the three core models and those in `config :forecast_loop, :models`.
- The backtest forecasts each question at its window start. It runs in one transaction that it rolls back. Inside the transaction it does these steps:
  1. Set `batch_context.as_of` to the window start.
  2. Run the model.
  3. Insert the forecast under a temporary agent.
  4. Read `cal_score`, `cal_summary` and `cal_bucket` for that agent.
- The backtest uses the same scoring views as the live system and stores nothing.

## Consequences

A backtest gives the same report each time on the same data. A backtest cannot see data that was published after the question's window start, so it uses the pre-revision values.
