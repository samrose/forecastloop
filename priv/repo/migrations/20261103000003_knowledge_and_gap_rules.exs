defmodule ForecastLoop.Repo.Migrations.KnowledgeAndGapRules do
  @moduledoc "Loads the k_* and gap_* rule views (phase 3). See docs/adr/0011."
  use Ecto.Migration

  def up, do: ForecastLoop.SQLFiles.reload_if_latest(__MODULE__, &execute/1)
  def down, do: ForecastLoop.SQLFiles.drop!(&execute/1)
end
