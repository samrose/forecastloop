defmodule ForecastLoop.Ledger.Assumption do
  @moduledoc "A statement a scenario depends on, optionally tested by a question."
  use ForecastLoop.Schema

  schema "assumptions" do
    field :statement, :string
    field :asserted_by, :string
    belongs_to :scenario, ForecastLoop.Ledger.Scenario
    belongs_to :question, ForecastLoop.Ledger.Question
    timestamps()
  end

  def changeset(assumption, attrs) do
    assumption
    |> cast(attrs, [:scenario_id, :statement, :question_id])
    |> ForecastLoop.Schema.provenance(attrs)
    |> validate_required([:scenario_id, :statement])
    |> foreign_key_constraint(:scenario_id)
    |> foreign_key_constraint(:question_id)
  end
end
