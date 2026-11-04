defmodule ForecastLoop.Models.Poisson do
  @moduledoc """
  Poisson model for events conditions (`count>=`, `count<=`).

  The event rate λ (events per second) comes from either:

  * `params.rate_signal`: the name of a series of event counts per period (for
    example a derived `aggregate_by_period` count). λ = mean of its last
    `trailing_n` as-of values (default 12) / the median spacing of the series; or
  * the matching events themselves over the `trailing_days` (default 365) before
    the forecast point.

  Events already in the window (before `as_of`) count. The remaining count is
  Poisson with mean λ × (remaining window time). For `count>= v`:
  P = P(N_remaining ≥ v − seen). For `count<= v`: P = P(N_remaining ≤ v − seen).
  """
  @behaviour ForecastLoop.Models

  alias ForecastLoop.Models.Events
  alias ForecastLoop.{Observations, Signals}

  @impl true
  def forecast(mv, q, as_of) do
    rc = q.resolution_condition

    if rc["type"] == "events", do: estimate(mv, q, rc, as_of), else: {:error, :not_applicable}
  end

  defp estimate(mv, q, rc, as_of) do
    {from, to} = Events.window(q)
    point = Enum.min([Enum.max([from, as_of], DateTime), to], DateTime)

    seen =
      rc["signal_id"]
      |> Events.times(rc["where"], point)
      |> Enum.count(&(DateTime.compare(&1, from) != :lt))

    with {:ok, rate, how, cited} <- rate(mv.params, rc, point) do
      mean = rate * DateTime.diff(to, point, :second)
      p = probability(rc["op"], rc["value"] - seen, mean)

      {:ok, p,
       "Poisson: #{seen} matching events so far; expected #{Float.round(mean, 3)} more in the window (#{how}).",
       Enum.uniq([rc["signal_id"] | cited])}
    end
  end

  defp probability("count>=", need, mean), do: 1.0 - cdf(need - 1, mean)
  defp probability("count<=", need, mean), do: cdf(need, mean)

  defp rate(%{"rate_signal" => name} = params, _rc, point) do
    case Signals.get_by_name(name) do
      nil ->
        {:error, {:unknown_rate_signal, name}}

      s ->
        pts = [s.id] |> Observations.as_of(point) |> Enum.reject(&is_nil(&1.value))
        pts = Enum.filter(pts, &(DateTime.compare(&1.effective_at, point) == :lt))
        recent = Enum.take(pts, -Map.get(params, "trailing_n", 12))

        case spacing(recent) do
          nil -> {:error, :not_enough_rate_history}
          sec -> {:ok, mean(Enum.map(recent, & &1.value)) / sec, "rate from #{name}", [s.id]}
        end
    end
  end

  defp rate(params, rc, point) do
    days = Map.get(params, "trailing_days", 365)
    start = DateTime.add(point, -days * 86_400, :second)

    n =
      rc["signal_id"]
      |> Events.times(rc["where"], point)
      |> Enum.count(&(DateTime.compare(&1, start) != :lt))

    {:ok, n / (days * 86_400), "#{n} matching events in the previous #{days} days", []}
  end

  defp spacing(points) when length(points) < 2, do: nil

  defp spacing(points) do
    gaps =
      points
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [a, b] -> DateTime.diff(b.effective_at, a.effective_at, :second) end)
      |> Enum.sort()

    Enum.at(gaps, div(length(gaps), 2))
  end

  defp mean(xs), do: Enum.sum(xs) / length(xs)

  @doc false
  # P(N <= k) for N ~ Poisson(mean). k < 0 gives 0.
  def cdf(k, _mean) when k < 0, do: 0.0

  def cdf(k, mean) do
    {sum, _term} =
      Enum.reduce(0..trunc(k), {0.0, :math.exp(-mean)}, fn i, {sum, term} ->
        next = if i == 0, do: term, else: term * mean / i
        {sum + next, next}
      end)

    min(sum, 1.0)
  end
end
