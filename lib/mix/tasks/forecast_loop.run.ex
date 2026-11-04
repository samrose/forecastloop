defmodule Mix.Tasks.ForecastLoop.Run do
  @shortdoc "Runs the forecasting batch once"
  @moduledoc """
  Runs the nightly batch once.

      mix forecast_loop.run
      mix forecast_loop.run --as-of 2026-09-30
      mix forecast_loop.run --as-of 2026-09-30T12:00:00Z --no-refresh

  `--as-of` replays the loop as of that time (a date means 00:00 UTC). `--no-refresh`
  skips fetching from sources.
  """
  use Mix.Task

  alias ForecastLoop.Batch.Runner
  alias ForecastLoop.Sources.Mapping

  @impl Mix.Task
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: [as_of: :string, refresh: :boolean])
    Mix.Task.run("app.start")

    run_opts =
      [refresh: Keyword.get(opts, :refresh, true)] ++
        case opts[:as_of] do
          nil -> []
          s -> [as_of: parse!(s)]
        end

    {status, run} = Runner.run(run_opts)
    Mix.shell().info("Run #{run.id} #{run.status} as of #{DateTime.to_iso8601(run.as_of)}")
    Mix.shell().info(Jason.encode!(run.stats, pretty: true))
    if status == :error, do: Mix.raise("batch run failed")
  end

  defp parse!(s) do
    case Mapping.parse_time(s, "iso8601") do
      {:ok, dt} -> dt
      {:error, _} -> Mix.raise("--as-of must be an ISO 8601 date or timestamp")
    end
  end
end
