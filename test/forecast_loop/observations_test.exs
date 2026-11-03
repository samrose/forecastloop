defmodule ForecastLoop.ObservationsTest do
  use ForecastLoop.DataCase, async: true

  alias ForecastLoop.Observations

  setup do
    s = signal()
    # September value published on 5 Oct, then revised on 5 Nov.
    observe(s, "2026-09", "2026-09-01T00:00:00Z", "2026-10-05T00:00:00Z", 4.1)
    observe(s, "2026-09", "2026-09-01T00:00:00Z", "2026-11-05T00:00:00Z", 4.4)
    # October value published on 5 Nov.
    observe(s, "2026-10", "2026-10-01T00:00:00Z", "2026-11-05T00:00:00Z", 4.6)
    %{s: s}
  end

  test "before any publication, nothing is known", %{s: s} do
    assert Observations.as_of([s.id], ts("2026-10-01T00:00:00Z")) == []
  end

  test "before the revision, the pre-revision value is returned", %{s: s} do
    assert [%{source_record_id: "2026-09", value: 4.1}] =
             Observations.as_of([s.id], ts("2026-10-20T00:00:00Z"))
  end

  test "after the revision, the revised value replaces it", %{s: s} do
    assert [%{value: 4.4}, %{source_record_id: "2026-10", value: 4.6}] =
             Observations.as_of([s.id], ts("2026-11-06T00:00:00Z"))
  end

  test "an observation is visible at exactly its observed_at", %{s: s} do
    assert [_, _] = Observations.as_of([s.id], ts("2026-11-05T00:00:00Z"))
  end

  test "only the requested signals are returned", %{s: s} do
    other = signal()
    observe(other, "x", "2026-09-01T00:00:00Z", "2026-09-02T00:00:00Z", 1.0)
    rows = Observations.as_of([s.id], ts("2027-01-01T00:00:00Z"))
    assert Enum.all?(rows, &(&1.signal_id == s.id))
  end

  test "two records with the same effective_at stay distinct" do
    e = signal(%{kind: "events"})
    observe(e, "evt-1", "2026-09-01T10:00:00Z", "2026-09-01T11:00:00Z", nil, %{"k" => "a"})
    observe(e, "evt-2", "2026-09-01T10:00:00Z", "2026-09-01T11:00:00Z", nil, %{"k" => "b"})
    assert length(Observations.as_of([e.id], ts("2026-09-02T00:00:00Z"))) == 2
  end

  test "the SQL function reads batch_context.as_of when called with it", %{s: s} do
    ForecastLoop.Batch.set_as_of(ts("2026-10-20T00:00:00Z"))

    %{rows: [[v]]} =
      Repo.query!(
        "SELECT value FROM observations_as_of((SELECT as_of FROM batch_context)) WHERE signal_id = $1",
        [s.id]
      )

    assert v == 4.1
  end
end
