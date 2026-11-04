defmodule ForecastLoop.CalibrationTest do
  @moduledoc """
  Scores and calibration against a hand-computed fixture.

  Agent A's final forecasts on six resolved questions in domain "d":

      p     outcome  brier     ln(p of outcome)   decile
      0.90  true     0.0100    ln 0.90            9
      0.80  true     0.0400    ln 0.80            8
      0.85  false    0.7225    ln 0.15            8
      0.30  false    0.0900    ln 0.70            3
      0.25  true     0.5625    ln 0.25            2
      0.05  false    0.0025    ln 0.95            0

  mean Brier = 1.4275 / 6 = 0.237916…
  base rate obar = 3/6 = 0.5, uncertainty = 0.25
  reliability = [0.1² + 2·(0.825 − 0.5)² + 0.3² + 0.75² + 0.05²] / 6 = 0.87625 / 6
  resolution  = [0.5² + 2·0² + 0.5² + 0.5² + 0.5²] / 6 = 1 / 6
  skill = 1 − 0.237916… / 0.25
  """
  use ForecastLoop.DataCase, async: false

  alias ForecastLoop.{Batch, Rules, Scores}
  alias ForecastLoop.Ledger.{Resolution, Score}

  @fixture [{0.90, true}, {0.80, true}, {0.85, false}, {0.30, false}, {0.25, true}, {0.05, false}]

  setup do
    a = agent("A")
    author = agent()

    qs =
      for {{p, outcome}, i} <- Enum.with_index(@fixture) do
        q = live_question(author, %{domain: "d"})
        # An earlier forecast that the final one replaces:
        forecast(q, a, 0.5, "2026-01-01T00:00:00Z")
        forecast(q, a, p, "2026-01-02T00:00:00Z")
        resolve(q, outcome, "2026-02-0#{i + 1}T00:00:00Z")
        # A forecast after the resolution is not scored:
        forecast(q, a, 0.99, "2026-03-01T00:00:00Z")
        q
      end

    Batch.set_as_of(ts("2026-06-01T00:00:00Z"))
    %{a: a, qs: qs}
  end

  test "cal_score scores every forecast made before resolution", %{a: a} do
    rows = Rules.rows("cal_score", "WHERE agent_id = #{a.id}")
    assert length(rows) == 12
    finals = rows |> Enum.filter(& &1["is_final"]) |> Enum.sort_by(& &1["probability"], :desc)
    assert Enum.map(finals, & &1["probability"]) == [0.9, 0.85, 0.8, 0.3, 0.25, 0.05]

    expected_brier = %{
      0.9 => 0.01,
      0.85 => 0.7225,
      0.8 => 0.04,
      0.3 => 0.09,
      0.25 => 0.5625,
      0.05 => 0.0025
    }

    expected_log = %{
      0.9 => :math.log(0.9),
      0.85 => :math.log(0.15),
      0.8 => :math.log(0.8),
      0.3 => :math.log(0.7),
      0.25 => :math.log(0.25),
      0.05 => :math.log(0.95)
    }

    for r <- finals do
      assert_in_delta r["brier"], expected_brier[r["probability"]], 1.0e-12
      assert_in_delta r["log_score"], expected_log[r["probability"]], 1.0e-12
    end
  end

  test "log score clips probabilities to [0.01, 0.99]" do
    q = live_question(agent(), %{domain: "clip"})
    b = agent()
    forecast(q, b, 0.0, "2026-01-01T00:00:00Z")
    resolve(q, true, "2026-01-05T00:00:00Z")
    [r] = Rules.rows("cal_score", "WHERE agent_id = #{b.id}")
    assert_in_delta r["log_score"], :math.log(0.01), 1.0e-12
    assert r["brier"] == 1.0
  end

  test "cal_bucket and cal_summary match the hand computation", %{a: a} do
    buckets = Rules.rows("cal_bucket", "WHERE agent_id = #{a.id} ORDER BY bucket")
    assert Enum.map(buckets, &{&1["bucket"], &1["n"]}) == [{0, 1}, {2, 1}, {3, 1}, {8, 2}, {9, 1}]
    b8 = Enum.find(buckets, &(&1["bucket"] == 8))
    assert_in_delta b8["mean_probability"], 0.825, 1.0e-12
    assert_in_delta b8["observed_frequency"], 0.5, 1.0e-12

    [s] = Rules.rows("cal_summary", "WHERE agent_id = #{a.id}")
    assert s["n"] == 6 and s["domain"] == "d" and s["agent_name"] == "A"
    assert_in_delta s["mean_brier"], 1.4275 / 6, 1.0e-12

    assert_in_delta s["mean_log_score"],
                    Enum.sum(Enum.map([0.9, 0.8, 0.15, 0.7, 0.25, 0.95], &:math.log/1)) / 6,
                    1.0e-12

    assert_in_delta s["base_rate"], 0.5, 1.0e-12
    assert_in_delta s["uncertainty"], 0.25, 1.0e-12
    assert_in_delta s["reliability"], 0.87625 / 6, 1.0e-12
    assert_in_delta s["resolution"], 1 / 6, 1.0e-12
    assert_in_delta s["skill"], 1 - 1.4275 / 6 / 0.25, 1.0e-12
  end

  test "deleting a resolution and refreshing removes only its scores; re-adding reproduces them",
       %{qs: [q1 | _]} do
    assert %{"upserted" => 12, "deleted" => 0} = Scores.refresh()

    before =
      Repo.all(from(s in Score, order_by: s.forecast_id))
      |> Enum.map(&{&1.forecast_id, &1.brier, &1.log_score})

    assert length(before) == 12

    assert %{"upserted" => 0, "deleted" => 0} = Scores.refresh()

    res = Repo.get_by!(Resolution, question_id: q1.id)
    Repo.delete!(res)
    assert %{"deleted" => 2, "upserted" => 0} = Scores.refresh()

    q1_forecasts =
      Repo.all(
        from(f in ForecastLoop.Ledger.Forecast, where: f.question_id == ^q1.id, select: f.id)
      )

    after_delete =
      Repo.all(from(s in Score, order_by: s.forecast_id))
      |> Enum.map(&{&1.forecast_id, &1.brier, &1.log_score})

    assert after_delete == Enum.reject(before, fn {fid, _, _} -> fid in q1_forecasts end)

    attrs =
      res
      |> Map.from_struct()
      |> Map.take([
        :question_id,
        :outcome,
        :resolved_at,
        :source,
        :evidence,
        :resolved_by,
        :asserted_by
      ])

    %Resolution{} |> Resolution.changeset(attrs) |> Repo.insert!()
    assert %{"upserted" => 2} = Scores.refresh()

    assert Repo.all(from(s in Score, order_by: s.forecast_id))
           |> Enum.map(&{&1.forecast_id, &1.brier, &1.log_score}) == before
  end
end
