defmodule Mix.Tasks.ForecastLoop.Backtest do
  @shortdoc "Replays a model version on resolved questions with as-of data"
  @moduledoc """
  Replays a model version on the resolved questions whose deadline is in the range,
  using only the data known at each question's window start. Prints each forecast,
  the Brier and log scores, and calibration. Stores nothing.

      mix forecast_loop.backtest --model 3 --from 2025-01-01 --to 2026-06-30
      mix forecast_loop.backtest --model 3 --from 2025-01-01 --to 2026-06-30 --json
  """
  use Mix.Task

  alias ForecastLoop.Sources.Mapping

  @impl Mix.Task
  def run(args) do
    {opts, _} =
      OptionParser.parse!(args,
        strict: [model: :integer, from: :string, to: :string, json: :boolean]
      )

    for k <- [:model, :from, :to], is_nil(opts[k]), do: Mix.raise("--#{k} is required")
    Mix.Task.run("app.start")

    report = ForecastLoop.Backtest.run(opts[:model], time!(opts[:from]), time!(opts[:to]))

    if opts[:json] do
      Mix.shell().info(Jason.encode!(report, pretty: true))
    else
      print(report)
    end
  end

  defp print(r) do
    Mix.shell().info(
      "Model version #{r.model_version_id}: #{length(r.forecasts)} forecasts on #{r.questions} questions (#{length(r.skipped)} skipped)"
    )

    for f <- r.forecasts do
      Mix.shell().info(
        "  q#{f.question_id} p=#{fmt(f.probability)} outcome=#{f.outcome} brier=#{fmt(f.brier)} log=#{fmt(f.log_score)}"
      )
    end

    for s <- r.summary do
      Mix.shell().info(
        "#{s["domain"]}: n=#{s["n"]} brier=#{fmt(s["mean_brier"])} log=#{fmt(s["mean_log_score"])} skill=#{fmt(s["skill"])} " <>
          "reliability=#{fmt(s["reliability"])} resolution=#{fmt(s["resolution"])} uncertainty=#{fmt(s["uncertainty"])}"
      )
    end

    for b <- r.buckets do
      Mix.shell().info(
        "  #{b["domain"]} decile #{b["bucket"]}: n=#{b["n"]} mean p=#{fmt(b["mean_probability"])} observed=#{fmt(b["observed_frequency"])}"
      )
    end
  end

  defp fmt(nil), do: "-"
  defp fmt(%Decimal{} = d), do: d |> Decimal.to_float() |> fmt()
  defp fmt(x) when is_float(x), do: :erlang.float_to_binary(x, decimals: 3)
  defp fmt(x), do: to_string(x)

  defp time!(s) do
    case Mapping.parse_time(s, "iso8601") do
      {:ok, t} -> t
      _ -> Mix.raise("bad date #{s}")
    end
  end
end
