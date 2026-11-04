defmodule ForecastLoop.Repo.Migrations.DeriveCompleteness do
  @moduledoc "Reloads the SQL files: sum/mean periods wait for their last input step. See docs/adr/0018."
  use Ecto.Migration

  def up, do: ForecastLoop.SQLFiles.reload_if_latest(__MODULE__, &execute/1)
  def down, do: ForecastLoop.SQLFiles.drop!(&execute/1)
end
