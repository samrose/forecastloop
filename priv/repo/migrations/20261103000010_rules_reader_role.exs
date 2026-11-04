defmodule ForecastLoop.Repo.Migrations.RulesReaderRole do
  @moduledoc """
  Creates forecast_loop_rules_reader, a NOLOGIN role that may read the rule views
  only. The application user becomes a member, so it can SET ROLE to it inside the
  read-only query transaction. Roles are cluster-wide, so creation is conditional.
  See docs/adr/0020.
  """
  use Ecto.Migration

  def up do
    execute """
    DO $$ BEGIN
      IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'forecast_loop_rules_reader') THEN
        CREATE ROLE forecast_loop_rules_reader NOLOGIN;
      END IF;
    END $$
    """

    execute "GRANT forecast_loop_rules_reader TO CURRENT_USER"
    ForecastLoop.SQLFiles.reload_if_latest(__MODULE__, &execute/1)
  end

  def down do
    ForecastLoop.SQLFiles.drop!(&execute/1)
    execute "REVOKE ALL ON observations, batch_context FROM forecast_loop_rules_reader"
  end
end
