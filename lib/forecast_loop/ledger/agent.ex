defmodule ForecastLoop.Ledger.Agent do
  @moduledoc "A forecaster. Humans, models and LLMs are scored identically."
  use ForecastLoop.Schema

  @kinds ~w(human model llm)

  schema "agents" do
    field :name, :string
    field :kind, :string
    field :asserted_by, :string
    timestamps()
  end

  def changeset(agent, attrs) do
    agent
    |> cast(attrs, [:name, :kind])
    |> ForecastLoop.Schema.provenance(attrs)
    |> validate_required([:name, :kind])
    |> validate_inclusion(:kind, @kinds)
    |> unique_constraint(:name)
    |> check_constraint(:kind, name: :kind_valid)
  end
end
