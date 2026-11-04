defmodule ForecastLoop.Models.BaseRate do
  @moduledoc """
  Base-rate model.

  * A question made from a template: the Laplace-smoothed share of the template's
    last `trailing_n` questions (default 12) that resolved true at or before `as_of`.
  * Otherwise, an events condition: the Laplace-smoothed share of the `trailing_n`
    windows of the same length, ending at the question's window start (or `as_of`
    if earlier), in which the condition held.
  * Otherwise: not applicable.

  Params: `trailing_n`.
  """
  @behaviour ForecastLoop.Models

  import Ecto.Query
  alias ForecastLoop.Ledger.{Question, Resolution}
  alias ForecastLoop.Models.Events
  alias ForecastLoop.Repo

  @impl true
  def forecast(mv, %Question{} = q, as_of) do
    n = Map.get(mv.params, "trailing_n", 12)

    cond do
      q.template_id -> from_template(q, as_of, n)
      q.resolution_condition["type"] == "events" -> from_events(q, as_of, n)
      true -> {:error, :not_applicable}
    end
  end

  defp from_template(q, as_of, n) do
    outcomes =
      Repo.all(
        from r in Resolution,
          join: p in Question,
          on: p.id == r.question_id,
          where: p.template_id == ^q.template_id and p.id != ^q.id and r.resolved_at <= ^as_of,
          order_by: [desc: r.resolved_at],
          limit: ^n,
          select: r.outcome
      )

    case {outcomes, q.resolution_condition["type"]} do
      {[], "events"} ->
        from_events(q, as_of, n)

      {[], _type} ->
        {:error, :not_applicable}

      _ ->
        hits = Enum.count(outcomes, & &1)
        p = Events.laplace(hits, length(outcomes))

        {:ok, p,
         "Base rate: #{hits} of the last #{length(outcomes)} questions from this template resolved true.",
         signal_ids(q)}
    end
  end

  defp from_events(q, as_of, n) do
    rc = q.resolution_condition
    {from, to} = Events.window(q)
    len = DateTime.diff(to, from, :second)
    stop = Enum.min([from, as_of], DateTime)
    start = DateTime.add(stop, -len * n, :second)
    times = Events.times(rc["signal_id"], rc["where"], stop)

    counts =
      for i <- 0..(n - 1) do
        lo = DateTime.add(start, len * i, :second)
        hi = DateTime.add(lo, len, :second)
        Enum.count(times, &(DateTime.compare(&1, lo) != :lt and DateTime.compare(&1, hi) == :lt))
      end

    if times == [] do
      {:error, :not_applicable}
    else
      hits = Enum.count(counts, &Events.count_ok?(&1, rc["op"], rc["value"]))
      p = Events.laplace(hits, n)

      {:ok, p,
       "Base rate: the condition held in #{hits} of the #{n} previous windows of the same length.",
       signal_ids(q)}
    end
  end

  defp signal_ids(%Question{resolution_condition: %{"signal_id" => id}}), do: [id]
  defp signal_ids(_q), do: []
end
