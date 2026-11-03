defmodule Mix.Tasks.ForecastLoop.Sql.Reload do
  @shortdoc "Drops and recreates the fl, derive and rules schemas from the SQL files"
  @moduledoc """
  Reloads every file in `priv/rules/manifest.txt` into the database, in one
  transaction. Use it while you edit a rule view. Commit the change with a new
  migration that calls `ForecastLoop.SQLFiles.reload_if_latest/2`, so other
  databases get it too (docs/adr/0011).

      mix forecast_loop.sql.reload
  """
  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")
    alias ForecastLoop.Repo

    {:ok, :ok} = Repo.transact(fn -> {:ok, ForecastLoop.SQLFiles.reload!(&Repo.query!/1)} end)
    Mix.shell().info("Reloaded #{length(ForecastLoop.SQLFiles.manifest())} SQL files.")
  end
end
