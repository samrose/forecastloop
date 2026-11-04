defmodule ForecastLoop.ModelsTest do
  use ForecastLoop.DataCase, async: false

  alias ForecastLoop.{Backtest, Batch, Ledger, Models}
  alias ForecastLoop.Batch.Act
  alias ForecastLoop.Models.Poisson

  @t0 "2020-01-01T00:00:00Z"

  defp mv(module, domains \\ ["test_domain"], params \\ %{}) do
    {:ok, a} = Ledger.ensure_agent("model:" <> module, "model")

    {:ok, mv} =
      Ledger.create_model_version(%{
        agent_id: a.id,
        model_module: "ForecastLoop.Models." <> module,
        version: "1",
        domains: domains,
        params: params,
        asserted_by: "t"
      })

    mv
  end

  defp month(i), do: ~D[2024-01-01] |> Date.shift(month: i) |> Date.to_iso8601()

  # A monthly series that rises 0.1 a month from 4.0 (2024-01) with a small wobble.
  defp rising(n \\ 24) do
    s = signal(%{name: "rising", cadence: "monthly"})

    for i <- 0..(n - 1),
        do:
          observe(
            s,
            month(i),
            month(i) <> "T00:00:00Z",
            @t0,
            4.0 + 0.1 * i + if(rem(i, 2) == 0, do: 0.05, else: -0.05)
          )

    s
  end

  describe "registry" do
    test "only registered modules run" do
      assert {:ok, ForecastLoop.Models.Poisson} = Models.module_for("ForecastLoop.Models.Poisson")

      assert {:error, {:unknown_model_module, "Elixir.System"}} =
               Models.module_for("Elixir.System")
    end
  end

  describe "SeriesThreshold" do
    test "a threshold the trend clears is likely; one far above it is unlikely" do
      s = rising()
      as_of = ts("2026-01-05T00:00:00Z")

      # Latest value 2025-12 = 4.0 + 2.3 - 0.05 = 6.25. The window's last month is 2026-03, 3 steps on.
      likely =
        live_question(agent(), %{
          resolution_condition:
            series_rc(s, ">=", 6.3, "2026-01-01T00:00:00Z", "2026-04-01T00:00:00Z")
        })

      unlikely =
        live_question(agent(), %{
          resolution_condition:
            series_rc(s, ">=", 9.0, "2026-01-01T00:00:00Z", "2026-04-01T00:00:00Z")
        })

      m = mv("SeriesThreshold")

      assert {:ok, p1, rationale, [sid]} = Models.run(m, likely, as_of)
      assert sid == s.id and p1 > 0.9
      assert rationale =~ "latest value 6.25" and rationale =~ "3-step paths"
      assert {:ok, p2, _, _} = Models.run(m, unlikely, as_of)
      assert p2 < 0.1
    end

    test "is not applicable to an events condition" do
      e = signal(%{kind: "events"})

      q =
        live_question(agent(), %{
          resolution_condition:
            events_rc(e, "count>=", 1, "2026-01-01T00:00:00Z", "2026-02-01T00:00:00Z")
        })

      assert {:error, :not_applicable} =
               Models.run(mv("SeriesThreshold"), q, ts("2026-01-01T00:00:00Z"))
    end
  end

  describe "Poisson" do
    test "cdf" do
      assert_in_delta Poisson.cdf(0, 2.0), :math.exp(-2.0), 1.0e-12
      assert_in_delta Poisson.cdf(2, 2.0), :math.exp(-2.0) * (1 + 2 + 2), 1.0e-12
      assert Poisson.cdf(-1, 2.0) == 0.0
    end

    test "P(at least one event) from the trailing event rate" do
      e = signal(%{kind: "events"})
      # 12 events in the 365 days before 2026-01-01: one a month.
      for i <- 0..11,
          do:
            observe(
              e,
              "e#{i}",
              Date.to_iso8601(Date.shift(~D[2025-01-15], month: i)) <> "T00:00:00Z",
              @t0,
              nil
            )

      q =
        live_question(agent(), %{
          resolution_condition:
            events_rc(e, "count>=", 1, "2026-01-01T00:00:00Z", "2026-01-31T00:00:00Z")
        })

      Batch.set_as_of(ts("2026-01-01T00:00:00Z"))
      assert {:ok, p, rationale, _} = Models.run(mv("Poisson"), q, ts("2026-01-01T00:00:00Z"))
      expected = 1 - :math.exp(-12 / 365 * 30)
      assert_in_delta p, expected, 1.0e-9
      assert rationale =~ "12 matching events in the previous 365 days"
    end

    test "events already in the window count" do
      e = signal(%{kind: "events"})
      observe(e, "a", "2026-01-03T00:00:00Z", @t0, nil)

      q =
        live_question(agent(), %{
          resolution_condition:
            events_rc(e, "count>=", 1, "2026-01-01T00:00:00Z", "2026-01-31T00:00:00Z")
        })

      Batch.set_as_of(ts("2026-01-10T00:00:00Z"))
      assert {:ok, 1.0, _, _} = Models.run(mv("Poisson"), q, ts("2026-01-10T00:00:00Z"))
    end
  end

  describe "BaseRate" do
    test "uses the template's resolved questions" do
      author = agent()

      {:ok, t} =
        Ledger.create_template(%{
          key: "t",
          domain: "test_domain",
          title_pattern: "x",
          event_definition_pattern: "x",
          resolution_condition_pattern: %{"type" => "manual"},
          cadence: "monthly",
          window_length: "P1M",
          starts_on: ~D[2025-01-01],
          created_by_id: author.id,
          asserted_by: "t"
        })

      for {outcome, i} <- Enum.with_index([true, false, true, true]) do
        q = live_question(author, %{template_id: t.id, template_period: "2025-0#{i + 1}"})
        resolve(q, outcome, "2025-0#{i + 2}-01T00:00:00Z")
      end

      q = live_question(author, %{template_id: t.id, template_period: "2025-09"})
      m = mv("BaseRate")
      assert {:ok, p, rationale, []} = Models.run(m, q, ts("2025-09-01T00:00:00Z"))
      assert_in_delta p, (3 + 1) / (4 + 2), 1.0e-12
      assert rationale =~ "3 of the last 4"

      # Only resolutions known at as_of count.
      assert {:ok, p_early, _, _} = Models.run(m, q, ts("2025-03-15T00:00:00Z"))
      assert_in_delta p_early, (1 + 1) / (2 + 2), 1.0e-12
    end

    test "uses trailing windows of the same length for an events condition" do
      e = signal(%{kind: "events"})
      # Events in 3 of the 12 monthly windows before 2026-01-01.
      for d <- ~w(2025-02-10 2025-06-10 2025-06-20 2025-11-10),
          do: observe(e, d, d <> "T00:00:00Z", @t0, nil)

      q =
        live_question(agent(), %{
          resolution_condition:
            events_rc(e, "count>=", 1, "2026-01-01T00:00:00Z", "2026-01-31T00:00:00Z")
        })

      Batch.set_as_of(ts("2026-01-01T00:00:00Z"))
      assert {:ok, p, _, _} = Models.run(mv("BaseRate"), q, ts("2026-01-01T00:00:00Z"))
      assert_in_delta p, (3 + 1) / (12 + 2), 1.0e-12
    end
  end

  test "the act step forecasts once for each live question a model covers" do
    s = rising()

    q =
      live_question(agent(), %{
        resolution_condition:
          series_rc(s, ">=", 6.3, "2026-01-01T00:00:00Z", "2026-04-01T00:00:00Z")
      })

    m = mv("SeriesThreshold")
    _other_domain = mv("Poisson", ["elsewhere"])
    as_of = ts("2026-01-05T00:00:00Z")
    Batch.set_as_of(as_of)

    assert %{"forecasts" => %{"made" => 1}} = Act.run(nil, as_of)
    assert %{"forecasts" => %{"made" => 0}} = Act.run(nil, as_of)
    [f] = Ledger.get_question_with_history!(q.id).forecasts

    assert f.model_version_id == m.id and f.agent_id == m.agent_id and f.made_at == as_of and
             f.cited_signal_ids == [s.id]
  end

  describe "backtest" do
    test "a backtest before a data revision uses the pre-revision value" do
      s = rising()
      # 2025-12 is first published as 6.25 (in rising/0); on 2026-02-10 it is revised to 9.0.
      observe(s, month(23), month(23) <> "T00:00:00Z", "2026-02-10T00:00:00Z", 9.0)

      q =
        live_question(agent(), %{
          deadline: ts("2026-04-01T00:00:00Z"),
          resolution_condition:
            series_rc(s, ">=", 6.3, "2026-01-01T00:00:00Z", "2026-04-01T00:00:00Z")
        })

      resolve(q, true, "2026-04-20T00:00:00Z")
      m = mv("SeriesThreshold")

      report = Backtest.run(m.id, ts("2026-01-01T00:00:00Z"), ts("2026-12-31T00:00:00Z"))
      assert [%{rationale: rationale, outcome: true, brier: brier}] = report.forecasts
      assert rationale =~ "latest value 6.25"
      refute rationale =~ "9.0"
      assert brier < 0.01
      assert [%{"n" => 1, "domain" => "test_domain"}] = report.summary

      # The backtest stores nothing.
      assert Ledger.get_question_with_history!(q.id).forecasts == []
    end

    test "a backtest gives the same report each time" do
      s = rising()
      author = agent()

      for {start, outcome} <- [{"2025-10-01", true}, {"2025-11-01", true}, {"2025-12-01", false}] do
        {:ok, d} = Date.from_iso8601(start)
        to = Date.shift(d, month: 1) |> Date.to_iso8601()

        q =
          live_question(author, %{
            deadline: ts(to <> "T00:00:00Z"),
            resolution_condition:
              series_rc(s, ">=", 5.0, start <> "T00:00:00Z", to <> "T00:00:00Z")
          })

        resolve(q, outcome, to <> "T10:00:00Z")
      end

      m = mv("SeriesThreshold")
      r1 = Backtest.run(m.id, ts("2025-01-01T00:00:00Z"), ts("2026-12-31T00:00:00Z"))
      r2 = Backtest.run(m.id, ts("2025-01-01T00:00:00Z"), ts("2026-12-31T00:00:00Z"))
      assert length(r1.forecasts) == 3
      assert r1 == r2
    end
  end
end
