defmodule ForecastLoop.Ledger.Score do
  @moduledoc """
  Brier and log score of one forecast. Derived only: the batch materializes this
  table from the `rules.cal_score` view. Do not write it by hand.
  """
  use ForecastLoop.Schema

  schema "scores" do
    field :brier, :float
    field :log_score, :float
    field :computed_at, :utc_datetime_usec
    field :asserted_by, :string
    belongs_to :forecast, ForecastLoop.Ledger.Forecast
    timestamps()
  end
end
