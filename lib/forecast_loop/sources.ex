defmodule ForecastLoop.Sources do
  @moduledoc """
  The behaviour that every data source implements, and the registry that maps a
  signal's `source_spec["system"]` to a source module.

  A source returns rows of this shape:

      %{source_record_id: String.t(), effective_at: DateTime.t(),
        observed_at: DateTime.t(), value: float() | nil, attributes: map()}

  A source returns `{:error, {:shape_changed, details}}` when the data no longer
  has the columns its spec declares. The refresh step then opens a
  `definition_change` work item and ingests nothing for that signal.

  Core systems: `"postgres"`, `"csv"`, `"http_csv"`, `"derived"`. A pack that
  needs another system adds its module under `config :forecast_loop, :sources`.
  """

  @type row :: %{
          source_record_id: String.t(),
          effective_at: DateTime.t(),
          observed_at: DateTime.t(),
          value: float() | nil,
          attributes: map()
        }

  @type spec :: map()

  @doc "Fetches rows. `since` is the latest observed_at already stored, or nil."
  @callback fetch(spec(), since :: DateTime.t() | nil) :: {:ok, [row()]} | {:error, term()}

  @doc "Fetches a sample of rows without storing them."
  @callback preview(spec()) :: {:ok, [row()]} | {:error, term()}

  @doc "One sentence that says what the source reads and which spec keys it uses."
  @callback describe() :: String.t()

  @core %{
    "postgres" => ForecastLoop.Sources.Postgres,
    "csv" => ForecastLoop.Sources.CSV,
    "http_csv" => ForecastLoop.Sources.HTTPCSV,
    "derived" => ForecastLoop.Sources.Derived
  }

  @doc "All registered systems: core systems plus those from `config :forecast_loop, :sources`."
  @spec systems() :: %{String.t() => module()}
  def systems, do: Map.merge(@core, Application.get_env(:forecast_loop, :sources, %{}))

  @doc "Returns the module for a spec's system."
  @spec module_for(spec()) :: {:ok, module()} | {:error, term()}
  def module_for(%{"system" => system}) do
    case Map.fetch(systems(), system) do
      {:ok, mod} -> {:ok, mod}
      :error -> {:error, {:unknown_system, system}}
    end
  end

  def module_for(_spec), do: {:error, :spec_has_no_system}

  @doc "Lists systems with descriptions, for the UI and the MCP `list_sources` tool."
  @spec list() :: [%{system: String.t(), module: module(), description: String.t()}]
  def list do
    systems()
    |> Enum.map(fn {system, mod} ->
      %{system: system, module: mod, description: mod.describe()}
    end)
    |> Enum.sort_by(& &1.system)
  end

  @doc "Previews a spec through its source module."
  @spec preview(spec()) :: {:ok, [row()]} | {:error, term()}
  def preview(spec) do
    with {:ok, mod} <- module_for(spec), do: mod.preview(spec)
  end
end
