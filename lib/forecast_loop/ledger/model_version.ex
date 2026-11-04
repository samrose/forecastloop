defmodule ForecastLoop.Ledger.ModelVersion do
  @moduledoc """
  One version of a forecasting model. `model_module` names the module that
  implements the `ForecastLoop.Models` behaviour (for example
  `"ForecastLoop.Models.BaseRate"`); `params` holds its options; `domains` lists
  the question domains it covers.
  """
  use ForecastLoop.Schema

  schema "model_versions" do
    field :version, :string
    field :model_module, :string
    field :params, :map, default: %{}
    field :domains, {:array, :string}, default: []
    field :notes, :string
    field :pack, :string
    field :asserted_by, :string
    belongs_to :agent, ForecastLoop.Ledger.Agent
    belongs_to :supersedes, __MODULE__
    timestamps()
  end

  def changeset(mv, attrs) do
    mv
    |> cast(attrs, [
      :agent_id,
      :model_module,
      :version,
      :params,
      :domains,
      :supersedes_id,
      :notes,
      :pack
    ])
    |> ForecastLoop.Schema.provenance(attrs)
    |> validate_required([:agent_id, :model_module, :version])
    |> unique_constraint([:agent_id, :version])
  end
end
