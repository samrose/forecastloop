defmodule ForecastLoop.GapsTest do
  use ForecastLoop.DataCase, async: false

  alias ForecastLoop.{Batch, Knowledge, Rules}
  alias ForecastLoop.Batch.Gaps

  @t0 "2026-01-01T00:00:00Z"

  defp fact(p, s, o, extra \\ %{}) do
    {:ok, f} =
      Knowledge.assert_fact(
        Map.merge(%{predicate: p, subject: s, object: o, asserted_by: "t"}, extra)
      )

    f
  end

  defp subjects(view), do: view |> Rules.rows() |> Enum.map(& &1["subject_id"]) |> Enum.sort()

  defp open_gaps(view),
    do: Batch.list_work_items(kind: "gap") |> Enum.filter(&(&1.subject_type == view))

  defp alerts,
    do:
      signal(%{
        name: "alerts",
        kind: "events",
        source_spec: %{"system" => "csv", "entity_attributes" => ["component"]}
      })

  setup do
    Batch.set_as_of(ts("2026-06-01T00:00:00Z"))
    :ok
  end

  test "gap_unknown_entity opens one work item; asserting a fact closes it" do
    a = alerts()
    observe(a, "1", "2026-01-10T00:00:00Z", @t0, nil, %{"component" => "svc-new"})
    observe(a, "2", "2026-01-11T00:00:00Z", @t0, nil, %{"component" => "svc-new"})

    assert %{"opened" => opened} = Gaps.run(nil)
    assert opened >= 1

    assert [
             %{
               subject_id: "svc-new",
               payload: %{"observations" => 2, "rule" => "gap_unknown_entity"}
             }
           ] =
             open_gaps("gap_unknown_entity")

    # Running again does not duplicate it.
    Gaps.run(nil)
    assert length(open_gaps("gap_unknown_entity")) == 1

    fact("entity_domain", "svc-new", "ops")
    assert %{"closed" => closed} = Gaps.run(nil)
    assert closed >= 1
    assert open_gaps("gap_unknown_entity") == []
  end

  test "gap_unclassified_event respects explicit negation" do
    a = alerts()

    fact("class_rule", "origin", "change_related", %{
      attributes: %{"equals" => "change", "negates" => ["hardware"], "signal" => "alerts"}
    })

    observe(a, "classified", "2026-01-10T00:00:00Z", @t0, nil, %{"origin" => "change"})
    observe(a, "negated", "2026-01-10T00:00:00Z", @t0, nil, %{"origin" => "hardware"})
    observe(a, "unknown", "2026-01-10T00:00:00Z", @t0, nil, %{"origin" => "cosmic rays"})
    assert subjects("gap_unclassified_event") == ["#{a.id}:unknown"]
  end

  test "signals without class rules produce no unclassified gaps" do
    a = alerts()
    observe(a, "1", "2026-01-10T00:00:00Z", @t0, nil, %{"origin" => "x"})
    assert subjects("gap_unclassified_event") == []
  end

  test "gap_unowned_domain and gap_insufficient_history" do
    q = question(agent(), %{domain: "ops"})
    assert subjects("gap_unowned_domain") == ["ops"]

    fact("min_history", "ops", "3")
    assert subjects("gap_unowned_domain") == []
    assert [%{"detail" => %{"have" => 0, "need" => 3}}] = Rules.rows("gap_insufficient_history")

    s = signal(%{domain: "ops"})
    for m <- ~w(01 02 03), do: observe(s, "2026-#{m}", "2026-#{m}-01T00:00:00Z", @t0, 1.0)
    assert subjects("gap_insufficient_history") == []
    assert q.domain == "ops"
  end

  test "gap_missing_signal" do
    author = agent()

    rc = fn id ->
      %{
        "type" => "series",
        "signal_id" => id,
        "op" => ">=",
        "value" => 1,
        "at" => "end_of_window"
      }
    end

    q1 = question(author, %{resolution_condition: rc.(999_999)})
    s = signal()
    q2 = question(author, %{resolution_condition: rc.(s.id)})
    events = signal(%{kind: "events"})
    observe(events, "e", "2025-01-01T00:00:00Z", @t0, nil)

    _q3 =
      question(author, %{
        resolution_condition: %{
          "type" => "events",
          "signal_id" => events.id,
          "op" => "count>=",
          "value" => 1
        }
      })

    reasons =
      Rules.rows("gap_missing_signal") |> Map.new(&{&1["subject_id"], &1["detail"]["reason"]})

    assert reasons == %{
             to_string(q1.id) => "signal_does_not_exist",
             to_string(q2.id) => "no_observations"
           }
  end

  test "gap_source_conflict uses the fact's tolerance" do
    a = signal(%{name: "pub_a"})
    b = signal(%{name: "pub_b"})
    f = fact("same_as", "pub_a", "pub_b", %{attributes: %{"tolerance" => 0.05}})
    observe(a, "2026-01", "2026-01-01T00:00:00Z", @t0, 4.00)
    observe(b, "2026-01", "2026-01-01T00:00:00Z", @t0, 4.04)
    observe(a, "2026-02", "2026-02-01T00:00:00Z", @t0, 4.0)
    observe(b, "2026-02", "2026-02-01T00:00:00Z", @t0, 4.3)

    assert [%{"subject_id" => sid, "detail" => %{"conflicts" => 1}}] =
             Rules.rows("gap_source_conflict")

    assert sid == to_string(f.id)
  end

  test "gap_definition_change flags a new attribute key or type in the latest refresh" do
    s = signal(%{kind: "events"})
    observe(s, "1", "2026-05-01T00:00:00Z", "2026-05-01T00:00:00Z", nil, %{"k" => "x"})
    observe(s, "2", "2026-05-10T00:00:00Z", "2026-05-10T00:00:00Z", nil, %{"k" => "y"})
    assert subjects("gap_definition_change") == []

    observe(s, "3", "2026-05-20T00:00:00Z", "2026-05-20T00:00:00Z", nil, %{
      "k" => 7,
      "extra" => "z"
    })

    assert [%{"detail" => %{"new_keys" => keys}}] = Rules.rows("gap_definition_change")
    assert keys == [%{"key" => "extra", "type" => "string"}, %{"key" => "k", "type" => "number"}]
  end

  test "gap_stale_source uses the cadence" do
    fresh = signal(%{cadence: "monthly"})
    stale = signal(%{cadence: "monthly"})
    _no_cadence = signal(%{})
    observe(fresh, "a", "2026-04-01T00:00:00Z", "2026-05-01T00:00:00Z", 1.0)
    observe(stale, "a", "2026-01-01T00:00:00Z", "2026-02-01T00:00:00Z", 1.0)
    assert subjects("gap_stale_source") == [to_string(stale.id)]
  end
end
