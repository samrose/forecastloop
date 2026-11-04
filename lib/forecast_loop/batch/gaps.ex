defmodule ForecastLoop.Batch.Gaps do
  @moduledoc """
  Batch step "Gaps": every row of every `rules.gap_*` view becomes an open work
  item of kind `gap`, with `subject_type` = the view name and `subject_id` = the
  row's `subject_id`. An open gap item whose row has gone (for example because a
  person asserted the missing fact) is closed. See docs/adr/0012.
  """
  alias ForecastLoop.{Batch, Rules}

  @spec run(integer() | nil) :: map()
  def run(run_id) do
    Rules.views("gap")
    |> Enum.map(&Batch.sync_work_items("gap", &1, Rules.rows(&1), run_id))
    |> Enum.reduce(
      %{"opened" => 0, "closed" => 0, "rows" => 0},
      &Map.merge(&1, &2, fn _k, a, b -> a + b end)
    )
  end
end
