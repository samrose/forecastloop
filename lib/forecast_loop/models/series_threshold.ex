defmodule ForecastLoop.Models.SeriesThreshold do
  @moduledoc """
  Model for series conditions. Let x0 be the latest as-of value before the window
  end, and h the number of steps (the series' median spacing) from x0 to the point
  the condition reads. The model takes every h-step path of the trailing
  `trailing_points` values (default 60) and applies its changes to x0:

  * `end_of_window`: x0 + (x[i+h] − x[i]) meets the op;
  * `any_in_window`: some x0 + (x[i+j] − x[i]), j = 1..h, meets the op;
  * `mean_in_window`: the mean of x0 + (x[i+j] − x[i]) over j meets the op.

  P is the Laplace-smoothed share of paths that meet the op. When the value is
  already known (h ≤ 0), P is 0.98 or 0.02.
  """
  @behaviour ForecastLoop.Models

  alias ForecastLoop.Models.Events
  alias ForecastLoop.Observations

  @impl true
  def forecast(mv, q, as_of) do
    rc = q.resolution_condition

    if rc["type"] != "series" do
      {:error, :not_applicable}
    else
      {_from, to} = Events.window(q)

      points =
        [rc["signal_id"]]
        |> Observations.as_of(as_of)
        |> Enum.reject(&is_nil(&1.value))
        |> Enum.filter(&(DateTime.compare(&1.effective_at, to) == :lt))

      estimate(points, rc, to, Map.get(mv.params, "trailing_points", 60))
    end
  end

  defp estimate(points, _rc, _to, _n) when length(points) < 3, do: {:error, :not_enough_history}

  defp estimate(points, rc, to, n) do
    values = Enum.map(points, & &1.value)
    last = List.last(points)
    step = median_spacing(points)

    # The condition reads the value of the window's last period, which starts one step before `to`.
    target = DateTime.add(to, -step, :second)
    h = round(DateTime.diff(target, last.effective_at, :second) / step)
    x0 = last.value
    op = rc["op"]
    v = rc["value"]

    if h <= 0 do
      known = if ok?(x0, op, v), do: 0.98, else: 0.02

      {:ok, known, "SeriesThreshold: the deciding value #{x0} is already known.",
       [rc["signal_id"]]}
    else
      trailing = Enum.take(values, -n)
      paths = paths(trailing, h)

      hits =
        Enum.count(paths, fn changes ->
          outcome(Enum.map(changes, &(x0 + &1)), rc["at"], op, v)
        end)

      p = Events.laplace(hits, length(paths))

      {:ok, p,
       "SeriesThreshold: latest value #{x0} at #{Date.to_iso8601(last.effective_at)}; #{hits} of #{length(paths)} historical #{h}-step paths meet #{op} #{v}.",
       [rc["signal_id"]]}
    end
  end

  # For each start i, the changes x[i+j] - x[i] for j = 1..h.
  defp paths(values, h) do
    arr = List.to_tuple(values)
    len = tuple_size(arr)

    if len <= h, do: [], else: Enum.map(0..(len - h - 1), &path(arr, &1, h))
  end

  defp path(arr, i, h) do
    for j <- 1..h, do: elem(arr, i + j) - elem(arr, i)
  end

  defp outcome(path, "any_in_window", op, v), do: Enum.any?(path, &ok?(&1, op, v))
  defp outcome(path, "mean_in_window", op, v), do: ok?(Enum.sum(path) / length(path), op, v)
  defp outcome(path, _end_of_window, op, v), do: ok?(List.last(path), op, v)

  defp ok?(x, ">=", v), do: x >= v
  defp ok?(x, "<=", v), do: x <= v
  defp ok?(x, ">", v), do: x > v
  defp ok?(x, "<", v), do: x < v

  defp median_spacing(points) do
    gaps =
      points
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [a, b] -> DateTime.diff(b.effective_at, a.effective_at, :second) end)
      |> Enum.sort()

    max(Enum.at(gaps, div(length(gaps), 2)), 1)
  end
end
