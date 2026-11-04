defmodule ForecastLoop.Repo.Migrations.Timestamptz do
  @moduledoc """
  Changes every application timestamp column from `timestamp` to `timestamptz`, so
  that comparisons with `timestamptz` values (such as `batch_context.as_of` in the
  rule views) never depend on the session time zone. Stored values are UTC.
  See docs/adr/0015.
  """
  use Ecto.Migration

  @columns %{
    "agents" => ~w(inserted_at updated_at),
    "scenarios" => ~w(inserted_at updated_at),
    "assumptions" => ~w(inserted_at updated_at),
    "question_templates" => ~w(inserted_at updated_at),
    "questions" => ~w(deadline inserted_at updated_at),
    "model_versions" => ~w(inserted_at updated_at),
    "forecasts" => ~w(made_at inserted_at updated_at),
    "resolutions" => ~w(resolved_at inserted_at updated_at),
    "scores" => ~w(computed_at inserted_at updated_at),
    "signals" => ~w(coverage_start coverage_end inserted_at updated_at),
    "observations" => ~w(effective_at observed_at inserted_at updated_at),
    "runs" => ~w(started_at finished_at as_of inserted_at updated_at),
    "regime_shifts" => ~w(effective_at inserted_at updated_at),
    "packs" => ~w(inserted_at updated_at),
    "knowledge_facts" => ~w(valid_from valid_to inserted_at updated_at),
    "work_items" => ~w(inserted_at updated_at),
    "batch_context" => ~w(as_of inserted_at updated_at),
    "config" => ~w(inserted_at updated_at)
  }

  def up do
    ForecastLoop.SQLFiles.drop!(&execute/1)
    convert("timestamptz", "AT TIME ZONE 'UTC'")
    ForecastLoop.SQLFiles.reload_if_latest(__MODULE__, &execute/1)
  end

  def down do
    ForecastLoop.SQLFiles.drop!(&execute/1)
    convert("timestamp", "AT TIME ZONE 'UTC'")
  end

  defp convert(type, using) do
    for {table, cols} <- @columns do
      alters = Enum.map_join(cols, ", ", &"ALTER COLUMN #{&1} TYPE #{type} USING #{&1} #{using}")
      execute "ALTER TABLE #{table} #{alters}"
    end
  end
end
