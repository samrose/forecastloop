defmodule ForecastLoop.Batch.Changepoints do
  @moduledoc """
  Batch step "Changepoints": runs `EDivisive.detect/2` on the as-of history of every
  series and derived signal and inserts a `regime_shifts` row for each change point.

  Detector options come from the `config` row `changepoint_detector` (defaults in
  `EDivisive.defaults/0`). The same row's `max_points` (default 240) limits the
  history to the latest values, so a long series does not slow the batch. The options, with the detector name, are stored as
  `detector_version`. A shift already stored for the same signal, effective_at and
  detector_version is not inserted again, so a rerun on the same data adds nothing.
  """
  alias ForecastLoop.{Observations, Repo, Signals}
  alias ForecastLoop.Signals.RegimeShift

  @detector "e_divisive/1"

  @spec run(integer() | nil, DateTime.t()) :: map()
  def run(run_id, %DateTime{} = as_of) do
    opts = options()
    max_points = max_points()

    version =
      Map.new(opts, fn {k, v} -> {to_string(k), v} end)
      |> Map.merge(%{"detector" => @detector, "max_points" => max_points})

    Signals.list_signals()
    |> Enum.filter(&(&1.kind in ["series", "derived"]))
    |> Enum.reduce(%{"signals" => 0, "shifts_found" => 0, "inserted" => 0}, fn s, acc ->
      points =
        [s.id]
        |> Observations.as_of(as_of)
        |> Enum.reject(&(is_nil(&1.value) or DateTime.compare(&1.effective_at, as_of) == :gt))
        |> Enum.take(-max_points)

      found = EDivisive.detect(Enum.map(points, & &1.value), opts)
      now = DateTime.utc_now()

      rows =
        for cp <- found do
          %{
            signal_id: s.id,
            effective_at: Enum.at(points, cp.index).effective_at,
            statistic: cp.statistic,
            p_value: cp.p_value,
            detector_version: version,
            run_id: run_id,
            asserted_by: "batch:changepoints",
            inserted_at: now,
            updated_at: now
          }
        end

      {n, _} =
        Repo.insert_all(RegimeShift, rows,
          on_conflict: :nothing,
          conflict_target: [:signal_id, :effective_at, :detector_version]
        )

      %{
        acc
        | "signals" => acc["signals"] + 1,
          "shifts_found" => acc["shifts_found"] + length(found),
          "inserted" => acc["inserted"] + n
      }
    end)
  end

  @doc "Detector options: `EDivisive.defaults/0` overridden by config `changepoint_detector`."
  @spec options() :: keyword()
  def options do
    stored = stored()

    Enum.map(EDivisive.defaults(), fn {k, default} ->
      {k, Map.get(stored, to_string(k), default)}
    end)
  end

  defp max_points, do: Map.get(stored(), "max_points", 240)

  defp stored do
    case Repo.query!("SELECT value FROM config WHERE key = 'changepoint_detector'") do
      %{rows: [[v]]} -> v
      _ -> %{}
    end
  end
end
