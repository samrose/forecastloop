defmodule ForecastLoop.Repo.Migrations.OrderedDeriveFunctions do
  @moduledoc "Reloads the SQL files: derive functions return rows in a fixed order. See docs/adr/0011."
  use Ecto.Migration

  def up, do: ForecastLoop.SQLFiles.reload_if_latest(__MODULE__, &execute/1)
  def down, do: ForecastLoop.SQLFiles.drop!(&execute/1)
end
