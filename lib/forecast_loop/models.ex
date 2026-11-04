defmodule ForecastLoop.Models do
  @moduledoc """
  The behaviour that every forecasting model implements, and the step that runs
  models for `rules.loop_needs_forecast`.

  A model version (`model_versions` row) names its module in `model_module`. The
  module must be registered: a core model, or one listed in
  `config :forecast_loop, :models`. A model forecasts under its own agent and is
  scored like any other agent.

  A model reads observations only through `ForecastLoop.Observations.as_of/2` with
  the `as_of` it is given, so a backtest sees only what was known then.
  """
  alias ForecastLoop.{Ledger, Rules}
  alias ForecastLoop.Ledger.{ModelVersion, Question}

  @doc """
  Returns the probability that `question` resolves true, a rationale, and the ids of
  the signals the forecast used. `{:error, :not_applicable}` means the model does not
  handle this kind of question.
  """
  @callback forecast(ModelVersion.t(), Question.t(), as_of :: DateTime.t()) ::
              {:ok, float(), String.t(), [integer()]} | {:error, term()}

  @core [
    ForecastLoop.Models.BaseRate,
    ForecastLoop.Models.Poisson,
    ForecastLoop.Models.SeriesThreshold
  ]

  @doc "Registered model modules."
  @spec modules() :: [module()]
  def modules, do: @core ++ Application.get_env(:forecast_loop, :models, [])

  @doc "The registered module named by a model version, or an error."
  @spec module_for(ModelVersion.t() | String.t()) :: {:ok, module()} | {:error, term()}
  def module_for(%ModelVersion{model_module: name}), do: module_for(name)

  def module_for(name) when is_binary(name) do
    case Enum.find(modules(), &(inspect(&1) == name)) do
      nil -> {:error, {:unknown_model_module, name}}
      mod -> {:ok, mod}
    end
  end

  @doc "Runs one model version on one question as of `as_of`, without storing anything."
  @spec run(ModelVersion.t(), Question.t(), DateTime.t()) ::
          {:ok, float(), String.t(), [integer()]} | {:error, term()}
  def run(%ModelVersion{} = mv, %Question{} = q, %DateTime{} = as_of) do
    with {:ok, mod} <- module_for(mv),
         {:ok, p, rationale, cited} <- mod.forecast(mv, q, as_of) do
      {:ok, clamp(p), rationale, cited}
    end
  end

  @doc """
  Batch action: for each row of `rules.loop_needs_forecast`, runs the model and
  appends its forecast with `made_at = as_of`. Returns counts.
  """
  @spec run_needed(DateTime.t()) :: %{String.t() => non_neg_integer()}
  def run_needed(%DateTime{} = as_of) do
    Rules.rows("loop_needs_forecast")
    |> Enum.reduce(%{"made" => 0, "not_applicable" => 0, "failed" => 0}, fn row, acc ->
      mv = Ledger.get_model_version!(row["model_version_id"])
      q = Ledger.get_question!(row["question_id"])

      case run(mv, q, as_of) do
        {:ok, p, rationale, cited} ->
          {:ok, _} =
            Ledger.submit_forecast(%{
              question_id: q.id,
              agent_id: mv.agent_id,
              model_version_id: mv.id,
              probability: p,
              rationale: rationale,
              cited_signal_ids: cited,
              made_at: as_of,
              asserted_by: "model:" <> mv.model_module
            })

          Map.update!(acc, "made", &(&1 + 1))

        {:error, :not_applicable} ->
          Map.update!(acc, "not_applicable", &(&1 + 1))

        {:error, _} ->
          Map.update!(acc, "failed", &(&1 + 1))
      end
    end)
  end

  defp clamp(p) when is_number(p), do: p |> max(0.0) |> min(1.0) |> Kernel.*(1.0)
end
