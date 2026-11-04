defmodule Mix.Tasks.ForecastLoop.Knowledge.Import do
  @shortdoc "Imports knowledge facts from CSV files (idempotent)"
  @moduledoc """
  Imports knowledge facts from one or more CSV files or directories of CSV files.
  Re-importing the same file changes nothing. See `ForecastLoop.Knowledge.import_csv/2`
  for the columns.

      mix forecast_loop.knowledge.import priv/packs/my_pack/knowledge
      mix forecast_loop.knowledge.import facts.csv --pack my_pack
  """
  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, paths} = OptionParser.parse!(args, strict: [pack: :string, asserted_by: :string])
    Mix.Task.run("app.start")

    if paths == [], do: Mix.raise("Give at least one CSV file or directory.")

    for file <- Enum.flat_map(paths, &expand/1) do
      case ForecastLoop.Knowledge.import_csv(file, opts) do
        {:ok, n} -> Mix.shell().info("#{file}: #{n} facts")
        {:error, reason} -> Mix.raise("#{file}: #{inspect(reason)}")
      end
    end
  end

  defp expand(path) do
    if File.dir?(path), do: Path.wildcard(Path.join(path, "*.csv")) |> Enum.sort(), else: [path]
  end
end
