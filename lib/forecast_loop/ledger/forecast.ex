defmodule ForecastLoop.Ledger.Forecast do
  @moduledoc """
  A probability that a question resolves true. Append-only: a database trigger
  rejects UPDATE and DELETE, so a revision is a new row.
  """
  use ForecastLoop.Schema

  schema "forecasts" do
    field :probability, :float
    field :rationale, :string, default: ""
    field :cited_signal_ids, {:array, :integer}, default: []
    field :made_at, :utc_datetime_usec
    field :asserted_by, :string
    belongs_to :question, ForecastLoop.Ledger.Question
    belongs_to :agent, ForecastLoop.Ledger.Agent
    belongs_to :model_version, ForecastLoop.Ledger.ModelVersion
    timestamps()
  end

  def changeset(forecast, attrs) do
    forecast
    |> cast(attrs, [
      :question_id,
      :agent_id,
      :model_version_id,
      :probability,
      :rationale,
      :cited_signal_ids,
      :made_at
    ])
    |> ForecastLoop.Schema.provenance(attrs)
    |> validate_required([:question_id, :agent_id, :probability, :made_at])
    |> validate_number(:probability, greater_than_or_equal_to: 0, less_than_or_equal_to: 1)
    |> check_constraint(:probability, name: :probability_range)
    |> foreign_key_constraint(:question_id)
    |> foreign_key_constraint(:agent_id)
  end
end
