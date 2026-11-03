defmodule ForecastLoop.Batch.Context do
  @moduledoc """
  The one-row `batch_context` table. Every rule view reads `as_of` from it, so the
  same views give historical results during a backtest.
  """
  use ForecastLoop.Schema

  @primary_key {:id, :boolean, autogenerate: false}
  schema "batch_context" do
    field :as_of, :utc_datetime_usec
    field :asserted_by, :string
    belongs_to :run, ForecastLoop.Batch.Run
    timestamps()
  end
end
