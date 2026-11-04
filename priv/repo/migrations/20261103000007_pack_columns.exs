defmodule ForecastLoop.Repo.Migrations.PackColumns do
  @moduledoc """
  Scenarios and model versions can come from a pack, like signals, knowledge facts
  and templates. Also reloads the SQL files (derived-period completeness).
  See docs/adr/0018.
  """
  use Ecto.Migration

  def up do
    alter table(:scenarios), do: add(:pack, :text)
    alter table(:model_versions), do: add(:pack, :text)
    ForecastLoop.SQLFiles.reload_if_latest(__MODULE__, &execute/1)
  end

  def down do
    alter table(:scenarios), do: remove(:pack)
    alter table(:model_versions), do: remove(:pack)
  end
end
