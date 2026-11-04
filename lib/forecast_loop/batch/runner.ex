defmodule ForecastLoop.Batch.Runner do
  @moduledoc """
  The nightly batch: one run of the loop, in nine steps. Each step is idempotent,
  so a second run on the same data changes only `runs` (and the `batch_context`
  row that points at the current run).

    1. Context: insert the run, set `batch_context.as_of`.
    2. Refresh: every non-derived signal (`ForecastLoop.Refresh.refresh_all/1`).
    3. Knowledge snapshot: `rules.k_*` to CSV (`ForecastLoop.Batch.Snapshot`).
    4. Derive: derived signals (`ForecastLoop.Refresh.derive_all/1`).
    5. Changepoints: `EDivisive` on series (`ForecastLoop.Batch.Changepoints`).
    6. Templates: questions for `loop_template_due` (`ForecastLoop.Batch.Templates`).
    7. Gaps: work items for `gap_*` rows (`ForecastLoop.Batch.Gaps`).
    8. Act: promote, resolve, score, forecast, work items (`ForecastLoop.Batch.Act`).
    9. Record: finish the run with the stats of every step.
  """
  require Logger
  alias ForecastLoop.{Batch, Refresh, Repo}
  alias ForecastLoop.Batch.{Act, Changepoints, Gaps, Run, Snapshot, Templates}

  @doc """
  Runs the batch. Options: `:as_of` (DateTime, default now), `:refresh` (default
  true; false skips step 2, for replays on stored data).
  Returns `{:ok, run}` or `{:error, run}`.
  """
  @spec run(keyword()) :: {:ok, Run.t()} | {:error, Run.t()}
  def run(opts \\ []) do
    as_of = Keyword.get_lazy(opts, :as_of, &DateTime.utc_now/0) |> usec()

    run =
      Repo.insert!(%Run{
        started_at: DateTime.utc_now(),
        as_of: as_of,
        status: "running",
        asserted_by: "batch"
      })

    Batch.set_as_of(as_of, run.id)

    steps = [
      {"refresh",
       fn ->
         if Keyword.get(opts, :refresh, true),
           do: Refresh.refresh_all(run_id: run.id),
           else: %{"skipped" => true}
       end},
      {"snapshot", fn -> Snapshot.write(run.id) end},
      {"derive", fn -> Refresh.derive_all(run_id: run.id) end},
      {"changepoints", fn -> Changepoints.run(run.id, as_of) end},
      {"templates", fn -> Templates.run(run.id) end},
      {"gaps", fn -> Gaps.run(run.id) end},
      {"act", fn -> Act.run(run.id, as_of) end}
    ]

    {status, stats} =
      Enum.reduce_while(steps, {"succeeded", %{}}, fn {name, fun}, {_, stats} ->
        try do
          {:cont, {"succeeded", Map.put(stats, name, fun.())}}
        rescue
          e ->
            Logger.error(
              "batch step #{name} failed: " <> Exception.format(:error, e, __STACKTRACE__)
            )

            {:halt, {"failed", Map.put(stats, name, %{"error" => Exception.message(e)})}}
        end
      end)

    run =
      run
      |> Ecto.Changeset.change(status: status, stats: stats, finished_at: DateTime.utc_now())
      |> Repo.update!()

    if status == "succeeded", do: {:ok, run}, else: {:error, run}
  end

  defp usec(%DateTime{} = dt),
    do: %{DateTime.shift_zone!(dt, "Etc/UTC") | microsecond: {elem(dt.microsecond, 0), 6}}
end
