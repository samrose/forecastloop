defmodule Mix.Tasks.ForecastLoop.Pack.Install do
  @shortdoc "Installs a domain pack from priv/packs/<name> or a folder (idempotent)"
  @moduledoc """
  Installs a domain pack folder into the database. See `ForecastLoop.Packs` for
  the folder format. Installing the same folder again changes nothing.

      mix forecast_loop.pack.install regional_economy
      mix forecast_loop.pack.install path/to/my_pack
  """
  use Mix.Task

  @impl Mix.Task
  def run([name_or_dir]) do
    Mix.Task.run("app.start")

    case ForecastLoop.Packs.install(name_or_dir) do
      {:ok, summary} -> Mix.shell().info(Jason.encode!(summary, pretty: true))
      {:error, reason} -> Mix.raise("pack install failed: #{inspect(reason)}")
    end
  end

  def run(_), do: Mix.raise("usage: mix forecast_loop.pack.install <name|folder>")
end
