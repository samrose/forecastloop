defmodule ForecastLoop.Batch.NightlyWorker do
  @moduledoc "Oban job that runs the nightly batch (`ForecastLoop.Batch.Runner.run/1`)."
  use Oban.Worker, queue: :batch, max_attempts: 1, unique: [period: 3600]

  alias ForecastLoop.Batch.Runner

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    opts =
      case args do
        %{"as_of" => iso} -> [as_of: elem(DateTime.from_iso8601(iso), 1)]
        _ -> []
      end

    case Runner.run(opts) do
      {:ok, _run} -> :ok
      {:error, run} -> {:error, "batch run #{run.id} failed"}
    end
  end
end
