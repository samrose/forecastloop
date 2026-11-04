defmodule ForecastLoop.DerivedTest do
  use ForecastLoop.DataCase, async: false

  alias ForecastLoop.{Batch, Observations, Refresh, Signals}
  alias ForecastLoop.Sources.Derived

  @t0 "2026-01-01T00:00:00Z"

  defp derived(name, spec) do
    {:ok, s} =
      Signals.register_signal(%{
        name: name,
        kind: "derived",
        source_spec: Map.put(spec, "system", "derived"),
        asserted_by: "test"
      })

    s
  end

  setup do
    Batch.set_as_of(ts("2026-04-01T00:00:00Z"))
    :ok
  end

  test "aggregate_by_period counts events per complete period, with zeros and groups" do
    ev = signal(%{name: "events_a", kind: "events"})
    observe(ev, "e1", "2026-01-05T10:00:00Z", @t0, nil, %{"kind" => "x", "entity" => "p"})
    observe(ev, "e2", "2026-01-20T10:00:00Z", @t0, nil, %{"kind" => "x", "entity" => "q"})
    observe(ev, "e3", "2026-01-21T10:00:00Z", @t0, nil, %{"kind" => "y", "entity" => "p"})
    observe(ev, "e4", "2026-03-02T10:00:00Z", @t0, nil, %{"kind" => "x", "entity" => "p"})
    # Not complete as of 2026-04-01, so not counted:
    observe(ev, "e5", "2026-04-10T10:00:00Z", @t0, nil, %{"kind" => "x", "entity" => "p"})

    spec = %{
      "operation" => "aggregate_by_period",
      "signal" => "events_a",
      "period" => "monthly",
      "agg" => "count",
      "where" => %{"kind" => "x"}
    }

    {:ok, rows} = Derived.compute(spec, Batch.as_of())

    assert Enum.map(rows, &{&1.source_record_id, &1.value}) == [
             {"2026-01", 2.0},
             {"2026-02", 0.0},
             {"2026-03", 1.0}
           ]

    assert hd(rows).attributes == %{"period" => "2026-01"}

    {:ok, grouped} = Derived.compute(Map.put(spec, "group_by", "entity"), Batch.as_of())

    assert grouped |> Enum.map(&{&1.source_record_id, &1.value}) |> Enum.sort() ==
             [
               {"2026-01:p", 1.0},
               {"2026-01:q", 1.0},
               {"2026-02:p", 0.0},
               {"2026-02:q", 0.0},
               {"2026-03:p", 1.0},
               {"2026-03:q", 0.0}
             ]

    {:ok, any_of} = Derived.compute(%{spec | "where" => %{"kind" => ["x", "y"]}}, Batch.as_of())
    assert hd(any_of).value == 3.0
  end

  test "change_over_periods gives differences and percent changes" do
    s = signal(%{name: "level"})

    for {m, v} <- [{"01", 10.0}, {"02", 12.0}, {"03", 9.0}],
        do: observe(s, "2026-#{m}", "2026-#{m}-01T00:00:00Z", @t0, v)

    {:ok, diff} =
      Derived.compute(
        %{"operation" => "change_over_periods", "signal" => "level", "lag" => 1},
        Batch.as_of()
      )

    assert Enum.map(diff, & &1.value) == [2.0, -3.0]

    {:ok, pct} =
      Derived.compute(
        %{
          "operation" => "change_over_periods",
          "signal" => "level",
          "lag" => 2,
          "mode" => "percent"
        },
        Batch.as_of()
      )

    assert Enum.map(pct, & &1.value) == [-10.0]
  end

  test "ratio divides matching records and skips a zero denominator" do
    a = signal(%{name: "num"})
    b = signal(%{name: "den"})
    observe(a, "2026-01", "2026-01-01T00:00:00Z", @t0, 3.0)
    observe(a, "2026-02", "2026-02-01T00:00:00Z", @t0, 1.0)
    observe(b, "2026-01", "2026-01-01T00:00:00Z", @t0, 4.0)
    observe(b, "2026-02", "2026-02-01T00:00:00Z", @t0, 0.0)

    {:ok, rows} =
      Derived.compute(
        %{"operation" => "ratio", "numerator" => "num", "denominator" => "den"},
        Batch.as_of()
      )

    assert Enum.map(rows, &{&1.source_record_id, &1.value}) == [{"2026-01", 0.75}]
  end

  test "derived inputs use as-of data" do
    s = signal(%{name: "level"})
    observe(s, "2026-01", "2026-01-01T00:00:00Z", "2026-02-01T00:00:00Z", 10.0)
    observe(s, "2026-02", "2026-02-01T00:00:00Z", "2026-03-01T00:00:00Z", 12.0)
    observe(s, "2026-02", "2026-02-01T00:00:00Z", "2026-03-15T00:00:00Z", 15.0)
    spec = %{"operation" => "change_over_periods", "signal" => "level", "lag" => 1}
    assert {:ok, [%{value: 2.0}]} = Derived.compute(spec, ts("2026-03-10T00:00:00Z"))

    assert {:ok, [%{value: 5.0, observed_at: obs}]} =
             Derived.compute(spec, ts("2026-03-20T00:00:00Z"))

    assert obs == ts("2026-03-15T00:00:00Z")
  end

  test "derive_all runs inputs first and is idempotent" do
    ev = signal(%{name: "events_a", kind: "events"})
    observe(ev, "e1", "2026-01-05T10:00:00Z", @t0, nil, %{})
    observe(ev, "e2", "2026-02-05T10:00:00Z", @t0, nil, %{})
    observe(ev, "e3", "2026-02-06T10:00:00Z", @t0, nil, %{})
    # Registered in reverse dependency order on purpose.
    change =
      derived("monthly_change", %{
        "operation" => "change_over_periods",
        "signal" => "monthly_count",
        "lag" => 1
      })

    count =
      derived("monthly_count", %{
        "operation" => "aggregate_by_period",
        "signal" => "events_a",
        "period" => "monthly",
        "agg" => "count"
      })

    assert %{"appended" => 5, "failed" => 0} = Refresh.derive_all()

    assert [%{value: 1.0}, %{value: 2.0}, %{value: +0.0}] =
             Observations.as_of([count.id], Batch.as_of())

    assert [%{value: 1.0}, %{value: -2.0}] = Observations.as_of([change.id], Batch.as_of())
    assert %{"appended" => 0} = Refresh.derive_all()
  end

  test "an unknown input signal fails the derived refresh" do
    s =
      derived("orphan", %{"operation" => "change_over_periods", "signal" => "missing", "lag" => 1})

    assert {:error, :refresh_failed, {:unknown_input_signal, "missing"}} =
             Refresh.refresh_signal(s)
  end

  test "sum and mean wait for the last input step of a period; count does not" do
    s = signal(%{name: "monthly_in", cadence: "monthly"})

    for {m, v} <- [{"01", 1.0}, {"02", 2.0}],
        do: observe(s, "2026-#{m}", "2026-#{m}-01T00:00:00Z", @t0, v)

    spec = %{
      "operation" => "aggregate_by_period",
      "signal" => "monthly_in",
      "period" => "quarterly",
      "agg" => "sum"
    }

    # As of 2026-04-01 the quarter has ended, but March is not published yet.
    assert {:ok, []} = Derived.compute(spec, Batch.as_of())
    observe(s, "2026-03", "2026-03-01T00:00:00Z", @t0, 3.0)

    assert {:ok, [%{source_record_id: "2026-Q1", value: 6.0}]} =
             Derived.compute(spec, Batch.as_of())
  end
end
