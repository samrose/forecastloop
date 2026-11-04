defmodule ForecastLoop.Batch.Act do
  @moduledoc """
  Batch step "Act". Each action reads one rule view and does what its rows say:

    1. `loop_live_question`: set the question live.
    2. `loop_resolvable`: resolve the question with the row's outcome and evidence.
       A row without an outcome (manual condition, or data not complete) opens a
       `needs_resolution` work item.
    3. Refresh `scores` from `cal_score`.
    4. `loop_needs_forecast`: run the model version and append its forecast.
    5. Work items for `loop_stale_forecast`, `loop_underspecified_question`,
       `loop_needs_revision` and `loop_needs_rethink`.
  """
  import Ecto.Query
  alias ForecastLoop.{Batch, Ledger, Models, Repo, Rules, Scores}
  alias ForecastLoop.Ledger.Question

  @work_item_views [
    {"loop_stale_forecast", "stale_forecast", "question_agent"},
    {"loop_underspecified_question", "underspecified_question", "question"},
    {"loop_needs_revision", "needs_revision", "model_version"},
    {"loop_needs_rethink", "needs_rethink", "scenario"}
  ]

  @spec run(integer() | nil, DateTime.t()) :: map()
  def run(run_id, as_of) do
    promoted = promote()
    {resolved, waiting} = resolve(as_of, run_id)
    scores = Scores.refresh()
    forecasts = Models.run_needed(as_of)

    items =
      for {view, kind, subject_type} <- @work_item_views, view in Rules.views(), into: %{} do
        {kind,
         Batch.sync_work_items(kind, subject_type, Rules.rows(view), run_id, view)["opened"]}
      end

    %{
      "promoted" => promoted,
      "resolved" => resolved,
      "awaiting_resolution" => waiting,
      "scores" => scores,
      "forecasts" => forecasts,
      "work_items_opened" => items
    }
  end

  defp promote do
    ids = Rules.rows("loop_live_question") |> Enum.map(& &1["question_id"])

    {n, _} =
      Repo.update_all(from(q in Question, where: q.id in ^ids and q.status == "review"),
        set: [
          status: "live",
          asserted_by: "rule:loop_live_question",
          updated_at: DateTime.utc_now()
        ]
      )

    n
  end

  defp resolve(as_of, run_id) do
    {known, unknown} = Enum.split_with(Rules.rows("loop_resolvable"), &is_boolean(&1["outcome"]))

    resolved =
      Enum.count(known, fn row ->
        q = Ledger.get_question!(row["question_id"])

        match?(
          {:ok, _},
          Ledger.resolve_question(q, %{
            outcome: row["outcome"],
            resolved_at: as_of,
            source: "rule:loop_resolvable:" <> row["reason"],
            evidence: row["evidence"],
            resolved_by: "batch",
            asserted_by: "batch"
          })
        )
      end)

    waiting =
      Enum.map(unknown, fn row ->
        %{
          "subject_id" => row["question_id"],
          "detail" => %{"question_id" => row["question_id"], "reason" => row["reason"]}
        }
      end)

    Batch.sync_work_items("needs_resolution", "question", waiting, run_id, "loop_resolvable")
    {resolved, length(waiting)}
  end
end
