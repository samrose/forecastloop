defmodule ForecastLoop.AppendOnlyTest do
  use ForecastLoop.DataCase, async: true

  alias ForecastLoop.Ledger
  alias ForecastLoop.Ledger.Forecast
  alias ForecastLoop.Signals.Observation

  defp forecast do
    q = question(agent())

    {:ok, f} =
      Ledger.submit_forecast(%{
        question_id: q.id,
        agent_id: q.created_by_id,
        probability: 0.3,
        asserted_by: "test"
      })

    f
  end

  test "a forecast cannot be updated" do
    f = forecast()

    assert_raise Postgrex.Error, ~r/append-only/, fn ->
      Repo.update_all(from(x in Forecast, where: x.id == ^f.id), set: [probability: 0.9])
    end
  end

  test "a forecast cannot be deleted" do
    f = forecast()
    assert_raise Postgrex.Error, ~r/append-only/, fn -> Repo.delete(f) end
  end

  test "a forecast revision is a new row" do
    f = forecast()

    {:ok, f2} =
      Ledger.submit_forecast(%{
        question_id: f.question_id,
        agent_id: f.agent_id,
        probability: 0.6,
        asserted_by: "test"
      })

    assert f2.id != f.id

    assert Repo.aggregate(from(x in Forecast, where: x.question_id == ^f.question_id), :count) ==
             2
  end

  test "an observation cannot be updated or deleted" do
    s = signal()
    observe(s, "2026-09", "2026-09-01T00:00:00Z", "2026-10-05T00:00:00Z", 4.1)
    [o] = Repo.all(from(x in Observation, where: x.signal_id == ^s.id))

    assert_raise Postgrex.Error, ~r/append-only/, fn ->
      Repo.update_all(from(x in Observation, where: x.id == ^o.id), set: [value: 9.9])
    end

    assert_raise Postgrex.Error, ~r/append-only/, fn -> Repo.delete(o) end
  end

  test "appending the same vintage twice inserts it once" do
    s = signal()

    row = %{
      signal_id: s.id,
      source_record_id: "2026-09",
      effective_at: ts("2026-09-01T00:00:00Z"),
      observed_at: ts("2026-10-05T00:00:00Z"),
      value: 4.1
    }

    assert ForecastLoop.Observations.append([row], "test") == 1
    assert ForecastLoop.Observations.append([row], "test") == 0
  end
end
