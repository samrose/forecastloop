defmodule ForecastLoop.Signals.RegimeShift do
  @moduledoc "A change point found by `EDivisive` in a series signal's as-of history."
  use ForecastLoop.Schema

  schema "regime_shifts" do
    field :effective_at, :utc_datetime_usec
    field :statistic, :float
    field :p_value, :float
    field :detector_version, :map, default: %{}
    field :asserted_by, :string
    belongs_to :signal, ForecastLoop.Signals.Signal
    belongs_to :run, ForecastLoop.Batch.Run
    timestamps()
  end
end
