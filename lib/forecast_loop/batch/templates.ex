defmodule ForecastLoop.Batch.Templates do
  @moduledoc """
  Batch step "Templates": makes one question in `review` status for each row of
  `rules.loop_template_due`. A person still reviews each question before it goes
  live. A row with a `problem` opens a `template_blocked` work item instead.
  """
  alias ForecastLoop.{Batch, Ledger, Rules}

  @spec run(integer() | nil) :: map()
  def run(run_id) do
    {ok, blocked} = Enum.split_with(Rules.rows("loop_template_due"), &is_nil(&1["problem"]))

    created =
      Enum.count(ok, fn row ->
        match?(
          {:ok, _},
          Ledger.create_question(%{
            title: row["title"],
            event_definition: row["event_definition"],
            resolution_condition: row["resolution_condition"],
            deadline: row["deadline"],
            domain: row["domain"],
            created_by_id: row["created_by_id"],
            template_id: row["template_id"],
            template_period: row["period"],
            asserted_by: "template:#{row["template_key"]}"
          })
        )
      end)

    blocked_rows =
      Enum.map(
        blocked,
        &%{
          "subject_id" => &1["template_id"],
          "detail" => Map.take(&1, ["template_key", "period", "problem"])
        }
      )

    sync =
      Batch.sync_work_items(
        "template_blocked",
        "question_template",
        blocked_rows,
        run_id,
        "loop_template_due"
      )

    %{"created" => created, "blocked" => length(blocked), "blocked_opened" => sync["opened"]}
  end
end
