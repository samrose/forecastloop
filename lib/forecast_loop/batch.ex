defmodule ForecastLoop.Batch do
  @moduledoc "Batch bookkeeping: the `batch_context` row, runs and work items."
  import Ecto.Query
  alias ForecastLoop.Batch.{Context, Run, WorkItem}
  alias ForecastLoop.Repo

  @doc "Returns the current `batch_context.as_of`."
  @spec as_of() :: DateTime.t()
  def as_of, do: Repo.one!(from c in Context, select: c.as_of)

  @doc "Sets `batch_context.as_of` (and the run it belongs to)."
  @spec set_as_of(DateTime.t(), integer() | nil, String.t()) :: :ok
  def set_as_of(%DateTime{} = t, run_id \\ nil, asserted_by \\ "batch") do
    {1, _} =
      Repo.update_all(Context,
        set: [as_of: t, run_id: run_id, asserted_by: asserted_by, updated_at: DateTime.utc_now()]
      )

    :ok
  end

  @doc "Runs `fun` with `batch_context.as_of` set to `t`, then restores the prior value."
  @spec with_as_of(DateTime.t(), (-> result)) :: result when result: var
  def with_as_of(%DateTime{} = t, fun) do
    prior = Repo.one!(from c in Context, select: {c.as_of, c.run_id})
    set_as_of(t, elem(prior, 1), "with_as_of")

    try do
      fun.()
    after
      set_as_of(elem(prior, 0), elem(prior, 1), "with_as_of")
    end
  end

  @doc "Lists work items, open first."
  def list_work_items(opts \\ []) do
    status = Keyword.get(opts, :status, "open")

    WorkItem
    |> where([w], w.status == ^status)
    |> then(fn q ->
      case Keyword.get(opts, :kind) do
        nil -> q
        k -> where(q, [w], w.kind == ^k)
      end
    end)
    |> order_by([w], asc: w.kind, asc: w.id)
    |> Repo.all()
  end

  @doc "Lists runs, newest first."
  def list_runs(limit \\ 50),
    do: Repo.all(from r in Run, order_by: [desc: r.id], limit: ^limit)
end
