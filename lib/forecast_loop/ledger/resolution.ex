defmodule ForecastLoop.Ledger.Resolution do
  @moduledoc "The outcome of a question, with the evidence for it."
  use ForecastLoop.Schema

  schema "resolutions" do
    field :outcome, :boolean
    field :resolved_at, :utc_datetime_usec
    field :source, :string
    field :evidence, :map, default: %{}
    field :resolved_by, :string
    field :asserted_by, :string
    belongs_to :question, ForecastLoop.Ledger.Question
    timestamps()
  end

  def changeset(resolution, attrs) do
    resolution
    |> cast(attrs, [:question_id, :outcome, :resolved_at, :source, :evidence, :resolved_by])
    |> ForecastLoop.Schema.provenance(attrs)
    |> validate_required([:question_id, :outcome, :resolved_at, :source, :resolved_by])
    |> unique_constraint(:question_id)
  end
end
