defmodule ForecastLoop.Signals.Observation do
  @moduledoc """
  One vintage of one source record. `effective_at` is when the measured thing
  happened; `observed_at` is when we learned this value. Append-only: a revised
  value is a new row with a later `observed_at`. Read through
  `ForecastLoop.Observations.as_of/2`.
  """
  use ForecastLoop.Schema

  schema "observations" do
    field :effective_at, :utc_datetime_usec
    field :observed_at, :utc_datetime_usec
    field :value, :float
    field :attributes, :map, default: %{}
    field :source_record_id, :string
    field :asserted_by, :string
    belongs_to :signal, ForecastLoop.Signals.Signal
    timestamps()
  end

  def changeset(obs, attrs) do
    obs
    |> cast(attrs, [
      :signal_id,
      :effective_at,
      :observed_at,
      :value,
      :attributes,
      :source_record_id
    ])
    |> ForecastLoop.Schema.provenance(attrs)
    |> validate_required([:signal_id, :effective_at, :observed_at, :source_record_id])
    |> unique_constraint([:signal_id, :source_record_id, :observed_at])
  end
end
