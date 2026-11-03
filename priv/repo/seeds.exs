# Core seed data. Idempotent: run it as often as you like with `mix run priv/repo/seeds.exs`.
#
# Only domain-neutral rows belong here. Domain content (signals, knowledge facts,
# templates, scenarios) comes from packs. See docs/adr/0004 and docs/adr/0009.
alias ForecastLoop.{Ledger, Repo}

now = DateTime.utc_now()

# Agents that the core itself uses. Model agents are made when a model version is registered.
{:ok, _} = Ledger.ensure_agent("system", "model", "seeds")

# Default rule parameters. The rule views read these from the `config` table.
config = [
  {"stale_forecast_threshold", %{"fraction_of_trailing_range" => 0.10, "trailing_days" => 30},
   "loop_stale_forecast: a cited signal must move by this fraction of its trailing range."},
  {"regime_shift_recent_window", %{"days" => 30},
   "loop_regime_shift_recent: how far back a regime shift counts as recent."},
  {"drift_windows", %{"recent_days" => 90, "baseline_days" => 365, "margin" => 0.05},
   "cal_drift: recent mean Brier must exceed baseline mean Brier by this margin."},
  {"definition_change_window", %{"days" => 30},
   "gap_definition_change: attribute keys and types are compared with this many prior days."},
  {"stale_source_multiple", %{"cadence_multiple" => 2},
   "gap_stale_source: a signal is stale after this many cadence periods with no new observation."}
]

for {key, value, note} <- config do
  Repo.query!(
    """
    INSERT INTO config (key, value, note, asserted_by, inserted_at, updated_at)
    VALUES ($1, $2, $3, 'seeds', $4, $4)
    ON CONFLICT (key) DO NOTHING
    """,
    [key, value, note, now]
  )
end
