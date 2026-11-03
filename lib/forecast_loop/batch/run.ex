defmodule ForecastLoop.Batch.Run do
  @moduledoc "One execution of the nightly batch, with counts per step in `stats`."
  use ForecastLoop.Schema

  schema "runs" do
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec
    field :as_of, :utc_datetime_usec
    field :status, :string, default: "running"
    field :stats, :map, default: %{}
    field :asserted_by, :string
    timestamps()
  end
end
