defmodule ForecastLoop.Scores do
  @moduledoc """
  The `scores` table is a materialization of `rules.cal_score`. `refresh/0` makes
  the table match the view: it deletes scores whose (forecast, resolution) row has
  gone, inserts new ones, and updates a score only when its values changed. So a
  refresh of unchanged data changes nothing. Do not write `scores` any other way.
  """
  alias ForecastLoop.Repo

  @spec refresh() :: %{String.t() => non_neg_integer()}
  def refresh do
    %{rows: [[deleted, upserted]]} =
      Repo.query!("""
      WITH s AS (SELECT forecast_id, brier, log_score FROM rules.cal_score),
      del AS (
        DELETE FROM scores WHERE forecast_id NOT IN (SELECT forecast_id FROM s) RETURNING 1
      ),
      up AS (
        INSERT INTO scores (forecast_id, brier, log_score, computed_at, asserted_by, inserted_at, updated_at)
        SELECT forecast_id, brier, log_score, now(), 'rule:cal_score', now(), now() FROM s
        ON CONFLICT (forecast_id) DO UPDATE
          SET brier = EXCLUDED.brier, log_score = EXCLUDED.log_score,
              computed_at = EXCLUDED.computed_at, updated_at = EXCLUDED.updated_at
          WHERE (scores.brier, scores.log_score) IS DISTINCT FROM (EXCLUDED.brier, EXCLUDED.log_score)
        RETURNING 1
      )
      SELECT (SELECT count(*) FROM del), (SELECT count(*) FROM up)
      """)

    %{"deleted" => deleted, "upserted" => upserted}
  end
end
