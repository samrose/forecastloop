defmodule Mix.Tasks.ForecastLoop.Pack.Export do
  @shortdoc "Exports an installed or in-app-built pack to a folder"
  @moduledoc """
  Writes a pack's database rows to a folder in the import format, for example to
  share a pack that a person built in the application.

      mix forecast_loop.pack.export my_pack path/to/my_pack
  """
  use Mix.Task

  @impl Mix.Task
  def run([name, dir]) do
    Mix.Task.run("app.start")

    case ForecastLoop.Packs.export(name, dir) do
      :ok -> Mix.shell().info("Exported #{name} to #{dir}")
      {:error, reason} -> Mix.raise("export failed: #{inspect(reason)}")
    end
  end

  def run(_), do: Mix.raise("usage: mix forecast_loop.pack.export <name> <folder>")
end
