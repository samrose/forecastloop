defmodule ForecastLoop.CollapseTest do
  @moduledoc """
  Predictability-collapse fixture: a monthly series with a planted shift produces a
  regime shift; forecasts in the domain deteriorate; cal_drift and
  cal_collapse_suspected flag the domain; the model covering it needs revision.
  """
  use ForecastLoop.DataCase, async: false

  alias ForecastLoop.{Batch, Ledger, Rules}
  alias ForecastLoop.Batch.{Act, Changepoints}
  alias ForecastLoop.Signals.RegimeShift

  @t0 "2020-01-01T00:00:00Z"

  defp month(i), do: Date.add(~D[2024-01-01], 0) |> Date.shift(month: i) |> Date.to_iso8601()

  setup do
    s = signal(%{name: "level", domain: "d", cadence: "monthly"})

    {noise, _} =
      Enum.map_reduce(0..35, :rand.seed_s(:exsss, {9, 9, 9}), fn _, st ->
        {u, st} = :rand.uniform_s(st)
        {u - 0.5, st}
      end)

    # 24 months near 4.0, then 12 months near 7.0: a shift at 2026-01-01.
    for {e, i} <- Enum.with_index(noise) do
      v = if i < 24, do: 4.0 + e, else: 7.0 + e
      observe(s, month(i), month(i) <> "T00:00:00Z", @t0, v)
    end

    %{s: s}
  end

  test "the planted shift becomes one regime shift, and a rerun inserts nothing", %{s: s} do
    as_of = ts("2027-01-01T00:00:00Z")
    Batch.set_as_of(as_of)
    assert %{"inserted" => 1} = Changepoints.run(nil, as_of)

    assert [%RegimeShift{effective_at: at, detector_version: %{"detector" => "e_divisive/1"}}] =
             Repo.all(RegimeShift)

    assert at == ~U[2026-01-01 00:00:00.000000Z]
    assert s.id == Repo.one!(from(r in RegimeShift, select: r.signal_id))
    assert %{"inserted" => 0, "shifts_found" => 1} = Changepoints.run(nil, as_of)
  end

  test "drift plus a recent shift on a cited signal is suspected collapse; the model needs revision",
       %{s: s} do
    as_of = ts("2026-07-01T00:00:00Z")
    Batch.set_as_of(as_of)
    Changepoints.run(nil, as_of)
    set_config("regime_shift_recent_window", %{"days" => 365})

    set_config("drift_windows", %{
      "recent_days" => 120,
      "baseline_days" => 365,
      "margin" => 0.1,
      "min_n" => 3
    })

    {:ok, model_agent} = Ledger.ensure_agent("model-a", "model")

    {:ok, mv} =
      Ledger.create_model_version(%{
        agent_id: model_agent.id,
        model_module: "ForecastLoop.Models.SeriesThreshold",
        version: "1",
        domains: ["d"],
        asserted_by: "t"
      })

    rc = series_rc(s, ">=", 5.0, "2025-01-01T00:00:00Z", "2025-02-01T00:00:00Z")
    author = agent()

    # Baseline (resolved 2025-06 to 2026-01): good forecasts. Recent (2026-04 to 2026-06): bad ones.
    for {p, outcome, resolved} <- [
          {0.1, false, "2025-06-01"},
          {0.1, false, "2025-08-01"},
          {0.2, false, "2025-10-01"},
          {0.1, true, "2026-04-01"},
          {0.2, true, "2026-05-01"},
          {0.1, true, "2026-06-01"}
        ] do
      q = live_question(author, %{domain: "d", resolution_condition: rc})
      forecast(q, model_agent, p, "2025-01-01T00:00:00Z", %{model_version_id: mv.id})
      resolve(q, outcome, resolved <> "T00:00:00Z")
    end

    assert [%{"domain" => "d", "recent_n" => 3, "baseline_n" => 3}] = Rules.rows("cal_drift")

    assert [%{"domain" => "d", "shifts" => [%{"signal_id" => sid}]}] =
             Rules.rows("cal_collapse_suspected")

    assert sid == s.id
    assert [%{"subject_id" => mv_id}] = Rules.rows("loop_needs_revision")
    assert mv_id == to_string(mv.id)

    Act.run(nil, as_of)

    assert [%{kind: "needs_revision", payload: %{"rule" => "loop_needs_revision"}}] =
             Batch.list_work_items(kind: "needs_revision")

    # A superseding version closes the old item. While the domain stays collapsed, the
    # rule flags the new current version too.
    {:ok, mv2} =
      Ledger.create_model_version(%{
        agent_id: model_agent.id,
        model_module: "ForecastLoop.Models.SeriesThreshold",
        version: "2",
        domains: ["d"],
        supersedes_id: mv.id,
        asserted_by: "t"
      })

    Act.run(nil, as_of)
    assert [%{subject_id: open_id}] = Batch.list_work_items(kind: "needs_revision")
    assert open_id == to_string(mv2.id)

    assert [%{subject_id: done_id}] =
             Batch.list_work_items(kind: "needs_revision", status: "done")

    assert done_id == to_string(mv.id)
  end

  test "drift without a recent shift is not collapse", %{s: _s} do
    set_config("drift_windows", %{
      "recent_days" => 120,
      "baseline_days" => 365,
      "margin" => 0.1,
      "min_n" => 1
    })

    Batch.set_as_of(ts("2026-07-01T00:00:00Z"))
    q1 = live_question(agent(), %{domain: "d"})
    q2 = live_question(agent(), %{domain: "d"})
    a = agent()
    forecast(q1, a, 0.1, "2025-01-01T00:00:00Z")
    forecast(q2, a, 0.1, "2025-01-01T00:00:00Z")
    resolve(q1, false, "2025-09-01T00:00:00Z")
    resolve(q2, true, "2026-05-01T00:00:00Z")
    assert [_] = Rules.rows("cal_drift")
    assert Rules.rows("cal_collapse_suspected") == []
  end
end
