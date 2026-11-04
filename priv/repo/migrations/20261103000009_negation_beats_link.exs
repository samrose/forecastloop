defmodule ForecastLoop.Repo.Migrations.NegationBeatsLink do
  @moduledoc "Reloads the SQL files: an explicit class_rule negation beats a link_rule. See docs/adr/0019."
  use Ecto.Migration

  def up, do: ForecastLoop.SQLFiles.reload_if_latest(__MODULE__, &execute/1)
  def down, do: ForecastLoop.SQLFiles.drop!(&execute/1)
end
