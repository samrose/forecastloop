defmodule ForecastLoop.Signals.Signal do
  @moduledoc """
  A data series or event stream. `source_spec` says how `ForecastLoop.Sources`
  fetches it: `%{"system" => ..., "query" => ..., "fields" => ..., "cadence" => ...}`.
  For a `derived` signal, `source_spec` names an Elixir function or a `rules.*` view.
  """
  use ForecastLoop.Schema

  schema "signals" do
    field :name, :string
    field :domain, :string
    field :kind, :string
    field :source_spec, :map, default: %{}
    field :units, :string
    field :cadence, :string
    field :coverage_start, :utc_datetime_usec
    field :coverage_end, :utc_datetime_usec
    field :definition_notes, :string
    field :pack, :string
    field :asserted_by, :string
    has_many :observations, ForecastLoop.Signals.Observation
    timestamps()
  end

  def changeset(signal, attrs) do
    signal
    |> cast(attrs, [
      :name,
      :domain,
      :kind,
      :source_spec,
      :units,
      :cadence,
      :coverage_start,
      :coverage_end,
      :definition_notes,
      :pack
    ])
    |> ForecastLoop.Schema.provenance(attrs)
    |> validate_required([:name, :kind, :source_spec])
    |> validate_inclusion(:kind, ~w(series events derived))
    |> unique_constraint(:name)
  end
end
