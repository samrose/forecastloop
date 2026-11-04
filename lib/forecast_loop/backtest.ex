defmodule ForecastLoop.Backtest do
  @moduledoc """
  Replays a model version on resolved questions with as-of data, and reports Brier
  and log scores and calibration from the `cal_*` views.

  For each resolved question with a deadline in `[from, to]` and a domain that the
  model covers, the backtest sets `batch_context.as_of` to the question's window
  start, runs the model, and inserts its forecast (made then) under a temporary
  backtest agent. It then reads `cal_score`, `cal_summary` and `cal_bucket` for that
  agent. Everything runs in one transaction that is rolled back, so a backtest
  stores nothing and gives the same result each time on the same data.
  """
  import Ecto.Query
  alias ForecastLoop.{Batch, Ledger, Models, Repo, Rules}
  alias ForecastLoop.Ledger.{Question, Resolution}
  alias ForecastLoop.Models.Events

  @end_of_time ~U[9999-12-31 00:00:00.000000Z]

  @type report :: %{
          model_version_id: integer(),
          questions: non_neg_integer(),
          forecasts: [map()],
          skipped: [map()],
          summary: [map()],
          buckets: [map()]
        }

  @spec run(integer(), DateTime.t(), DateTime.t()) :: report()
  def run(model_version_id, %DateTime{} = from, %DateTime{} = to) do
    {:error, {:report, report}} =
      Repo.transaction(fn -> Repo.rollback({:report, replay(model_version_id, from, to)}) end)

    report
  end

  defp replay(mv_id, from, to) do
    mv = Ledger.get_model_version!(mv_id)

    {:ok, agent} =
      Ledger.create_agent(%{
        name: "backtest:#{mv_id}:#{System.unique_integer([:positive])}",
        kind: "model",
        asserted_by: "backtest"
      })

    questions =
      Repo.all(
        from q in Question,
          join: r in Resolution,
          on: r.question_id == q.id,
          where: q.deadline >= ^from and q.deadline <= ^to and q.domain in ^mv.domains,
          order_by: [q.deadline, q.id]
      )

    {made, skipped} =
      Enum.reduce(questions, {[], []}, fn q, {made, skipped} ->
        {window_from, _} = Events.window(q)
        Batch.set_as_of(window_from)

        case Models.run(mv, q, window_from) do
          {:ok, p, rationale, cited} ->
            {:ok, f} =
              Ledger.submit_forecast(%{
                question_id: q.id,
                agent_id: agent.id,
                probability: p,
                rationale: rationale,
                cited_signal_ids: cited,
                made_at: window_from,
                asserted_by: "backtest"
              })

            {[
               %{
                 question_id: q.id,
                 forecast_id: f.id,
                 made_at: window_from,
                 probability: p,
                 rationale: rationale
               }
               | made
             ], skipped}

          {:error, reason} ->
            {made, [%{question_id: q.id, reason: inspect(reason)} | skipped]}
        end
      end)

    Batch.set_as_of(@end_of_time)

    scores =
      Map.new(Rules.rows("cal_score", "WHERE agent_id = #{agent.id}"), &{&1["forecast_id"], &1})

    forecasts =
      made
      |> Enum.reverse()
      |> Enum.map(fn m ->
        s = scores[m.forecast_id]

        m
        |> Map.delete(:forecast_id)
        |> Map.merge(%{outcome: s["outcome"], brier: s["brier"], log_score: s["log_score"]})
      end)

    %{
      model_version_id: mv_id,
      questions: length(questions),
      forecasts: forecasts,
      skipped: Enum.reverse(skipped),
      summary:
        Rules.rows("cal_summary", "WHERE agent_id = #{agent.id} ORDER BY domain")
        |> Enum.map(&Map.drop(&1, ["agent_id", "agent_name"])),
      buckets:
        Rules.rows("cal_bucket", "WHERE agent_id = #{agent.id} ORDER BY domain, bucket")
        |> Enum.map(&Map.delete(&1, "agent_id"))
    }
  end
end
