defmodule ForecastLoop.Models.Events do
  @moduledoc """
  Shared helpers for models: the times of events that match a question's events
  condition (signal, `where` attributes and `where.class`), as known at
  `batch_context.as_of`. The batch and the backtest set `batch_context.as_of` to the
  model's `as_of` before they call a model.
  """
  alias ForecastLoop.Repo

  @doc "Effective times (sorted) of matching events of `signal_id` with effective_at < `before`."
  @spec times(integer(), map(), DateTime.t()) :: [DateTime.t()]
  def times(signal_id, where_filter, %DateTime{} = before) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT n.effective_at
        FROM rules.k_observation_normalized n
        WHERE n.signal_id = $1 AND n.effective_at < $3
          AND fl.attrs_match(n.attributes, $2)
          AND ($2 -> 'class' IS NULL OR EXISTS (
            SELECT 1 FROM rules.k_event_class c
            WHERE c.observation_id = n.observation_id
              AND CASE jsonb_typeof($2 -> 'class')
                    WHEN 'array' THEN ($2 -> 'class') @> to_jsonb(c.class)
                    ELSE $2 ->> 'class' = c.class END))
        ORDER BY n.effective_at
        """,
        [signal_id, where_filter || %{}, before]
      )

    List.flatten(rows)
  end

  @doc "The question's window as {from, to}, with the defaults of rules.loop_question_window."
  @spec window(ForecastLoop.Ledger.Question.t()) :: {DateTime.t(), DateTime.t()}
  def window(q) do
    w = q.resolution_condition["window"] || %{}
    {parse(w["from"]) || q.inserted_at, parse(w["to"]) || q.deadline}
  end

  defp parse(nil), do: nil

  defp parse(s) do
    {:ok, dt, _} = DateTime.from_iso8601(s)
    dt
  end

  @doc "Laplace-smoothed share: (hits + 1) / (n + 2)."
  def laplace(hits, n), do: (hits + 1) / (n + 2)

  @doc "Checks a count against an events op."
  def count_ok?(count, "count>=", v), do: count >= v
  def count_ok?(count, "count<=", v), do: count <= v
end
