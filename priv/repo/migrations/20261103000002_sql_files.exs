defmodule ForecastLoop.Repo.Migrations.SqlFiles do
  @moduledoc """
  Loads helper functions, derived-series operations and rule views from files.
  Only the newest migration reloads them; see docs/adr/0011.
  """
  use Ecto.Migration

  def up, do: ForecastLoop.SQLFiles.reload_if_latest(__MODULE__, &execute/1)
  def down, do: ForecastLoop.SQLFiles.drop!(&execute/1)
end
