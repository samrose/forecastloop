defmodule ForecastLoop.Repo.Migrations.LoopAndCalibrationRules do
  @moduledoc "Loads the loop_* and cal_* rule views (phases 4 to 6). See docs/adr/0011."
  use Ecto.Migration

  def up, do: ForecastLoop.SQLFiles.reload_if_latest(__MODULE__, &execute/1)
  def down, do: ForecastLoop.SQLFiles.drop!(&execute/1)
end
