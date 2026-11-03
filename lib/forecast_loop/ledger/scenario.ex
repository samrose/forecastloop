defmodule ForecastLoop.Ledger.Scenario do
  @moduledoc "A narrative about a possible future, broken into testable assumptions."
  use ForecastLoop.Schema

  schema "scenarios" do
    field :title, :string
    field :narrative, :string, default: ""
    field :domain, :string
    field :status, :string, default: "active"
    field :asserted_by, :string
    has_many :assumptions, ForecastLoop.Ledger.Assumption
    timestamps()
  end

  def changeset(scenario, attrs) do
    scenario
    |> cast(attrs, [:title, :narrative, :domain, :status])
    |> ForecastLoop.Schema.provenance(attrs)
    |> validate_required([:title])
    |> validate_inclusion(:status, ~w(draft active retired))
  end
end
