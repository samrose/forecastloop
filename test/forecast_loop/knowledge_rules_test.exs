defmodule ForecastLoop.KnowledgeRulesTest do
  use ForecastLoop.DataCase, async: false

  alias ForecastLoop.{Batch, Knowledge, Rules}

  @t0 "2026-01-01T00:00:00Z"

  defp fact(p, s, o, extra \\ %{}),
    do:
      {:ok, _} =
        Knowledge.assert_fact(
          Map.merge(%{predicate: p, subject: s, object: o, asserted_by: "t"}, extra)
        )

  defp alerts,
    do:
      signal(%{
        name: "alerts",
        kind: "events",
        domain: "fallback",
        source_spec: %{"system" => "csv", "entity_attributes" => ["component"]}
      })

  defp changes,
    do:
      signal(%{
        name: "changes",
        kind: "events",
        source_spec: %{"system" => "csv", "entity_attributes" => ["component"]}
      })

  defp by_record(view, signal) do
    Rules.rows(view)
    |> Enum.filter(&(&1["signal_id"] == signal.id))
  end

  defp classes(signal) do
    ids =
      Map.new(
        Rules.rows("k_observation_normalized"),
        &{&1["observation_id"], &1["source_record_id"]}
      )

    Rules.rows("k_event_class")
    |> Enum.filter(&(&1["signal_id"] == signal.id))
    |> Enum.map(&{ids[&1["observation_id"]], &1["class"]})
    |> Enum.sort()
  end

  setup do
    Batch.set_as_of(ts("2026-12-01T00:00:00Z"))
    :ok
  end

  test "value_alias applies only inside its validity range; entity_alias applies to declared entity attributes" do
    a = alerts()
    fact("value_alias", "level:L0", "critical", %{valid_to: ts("2026-03-01T00:00:00Z")})
    fact("entity_alias", "svc-a-old", "svc-a")

    observe(a, "1", "2026-02-15T00:00:00Z", @t0, nil, %{
      "level" => "L0",
      "component" => "svc-a-old",
      "note" => "svc-a-old"
    })

    observe(a, "2", "2026-03-15T00:00:00Z", @t0, nil, %{
      "level" => "L0",
      "component" => ["svc-a-old", "svc-b"]
    })

    [one, two] =
      by_record("k_observation_normalized", a) |> Enum.sort_by(& &1["source_record_id"])

    assert one["attributes"] == %{
             "level" => "critical",
             "component" => "svc-a",
             "note" => "svc-a-old"
           }

    assert one["raw_attributes"]["level"] == "L0"
    assert two["attributes"] == %{"level" => "L0", "component" => ["svc-a", "svc-b"]}

    assert by_record("k_event_entity", a) |> Enum.map(& &1["entity"]) |> Enum.sort() == [
             "svc-a",
             "svc-a",
             "svc-b"
           ]
  end

  test "narrowing a value_alias valid_to reclassifies only events in the affected range" do
    a = alerts()

    {:ok, alias_fact} =
      Knowledge.assert_fact(%{
        predicate: "value_alias",
        subject: "level:L0",
        object: "critical",
        asserted_by: "t"
      })

    fact("class_rule", "level", "urgent", %{attributes: %{"equals" => "critical"}})

    for {id, day} <- [{"jan", "01-10"}, {"feb", "02-10"}, {"apr", "04-10"}],
        do: observe(a, id, "2026-#{day}T00:00:00Z", @t0, nil, %{"level" => "L0"})

    assert classes(a) == [{"apr", "urgent"}, {"feb", "urgent"}, {"jan", "urgent"}]

    {:ok, _} = Knowledge.update_fact(alias_fact, %{valid_to: ts("2026-03-01T00:00:00Z")})
    assert classes(a) == [{"feb", "urgent"}, {"jan", "urgent"}]
  end

  test "class_rule matches a value or a list, and can be limited to a signal" do
    a = alerts()
    c = changes()

    fact("class_rule", "origin", "change_related", %{
      attributes: %{"equals" => ["change", "rollout"], "signal" => "alerts"}
    })

    observe(a, "x", "2026-01-10T00:00:00Z", @t0, nil, %{"origin" => "rollout"})
    observe(a, "y", "2026-01-10T00:00:00Z", @t0, nil, %{"origin" => "hardware"})
    observe(c, "z", "2026-01-10T00:00:00Z", @t0, nil, %{"origin" => "change"})
    assert classes(a) == [{"x", "change_related"}]
    assert classes(c) == []
  end

  test "link_rule links an event to an earlier event on the same entity within the window" do
    a = alerts()
    c = changes()

    fact("link_rule", "alerts->changes", "change_related", %{
      attributes: %{"on" => "component", "within" => "PT24H"}
    })

    fact("entity_alias", "svc-a-old", "svc-a")
    observe(c, "c1", "2026-01-10T00:00:00Z", @t0, nil, %{"component" => "svc-a-old"})
    observe(a, "in_window", "2026-01-10T20:00:00Z", @t0, nil, %{"component" => "svc-a"})
    observe(a, "too_late", "2026-01-12T00:00:00Z", @t0, nil, %{"component" => "svc-a"})
    observe(a, "before", "2026-01-09T00:00:00Z", @t0, nil, %{"component" => "svc-a"})
    observe(a, "other_entity", "2026-01-10T20:00:00Z", @t0, nil, %{"component" => "svc-z"})
    assert classes(a) == [{"in_window", "change_related"}]
  end

  test "link_rule can name a different attribute in each signal" do
    a = alerts()

    c =
      signal(%{
        name: "changes",
        kind: "events",
        source_spec: %{"system" => "csv", "entity_attributes" => ["target"]}
      })

    fact("link_rule", "alerts→changes", "change_related", %{
      attributes: %{"on" => ["component", "target"], "within" => "P1D"}
    })

    observe(c, "c1", "2026-01-10T00:00:00Z", @t0, nil, %{"target" => "svc-a"})
    observe(a, "a1", "2026-01-10T05:00:00Z", @t0, nil, %{"component" => "svc-a"})
    assert classes(a) == [{"a1", "change_related"}]
  end

  test "k_event_domain follows entity_attr to an entity_domain, else the signal's domain" do
    a = alerts()
    fact("entity_attr", "svc-a", "team=team-x")
    fact("entity_domain", "team-x", "ops")
    observe(a, "1", "2026-01-10T00:00:00Z", @t0, nil, %{"component" => "svc-a"})
    observe(a, "2", "2026-01-10T00:00:00Z", @t0, nil, %{"component" => "svc-unknown"})

    ids =
      Map.new(
        by_record("k_observation_normalized", a),
        &{&1["observation_id"], &1["source_record_id"]}
      )

    domains =
      Rules.rows("k_event_domain")
      |> Enum.filter(&Map.has_key?(ids, &1["observation_id"]))
      |> Enum.map(&{ids[&1["observation_id"]], &1["domain"], &1["via_entity"]})
      |> Enum.sort()

    assert domains == [{"1", "ops", "team-x"}, {"2", "fallback", nil}]
  end

  test "k_series_canonical groups same_as signals transitively and picks by priority" do
    for n <- ~w(pub_a pub_b pub_c), do: signal(%{name: n})
    fact("same_as", "pub_a", "pub_b")
    fact("same_as", "pub_b", "pub_c", %{attributes: %{"priority" => %{"pub_a" => 0}}})

    rows =
      Rules.rows("k_series_canonical")
      |> Enum.map(&{&1["signal_name"], &1["canonical_signal_name"]})
      |> Enum.sort()

    assert rows == [{"pub_a", "pub_a"}, {"pub_b", "pub_a"}, {"pub_c", "pub_a"}]
  end

  test "an explicit negative beats a link_rule" do
    a = alerts()
    c = changes()

    fact("link_rule", "alerts->changes", "change_related", %{
      attributes: %{"on" => "component", "within" => "PT24H"}
    })

    fact("class_rule", "origin", "change_related", %{
      attributes: %{"equals" => "change", "negates" => ["hardware"]}
    })

    observe(c, "c1", "2026-01-10T00:00:00Z", @t0, nil, %{"component" => "svc-a"})
    observe(a, "linked", "2026-01-10T05:00:00Z", @t0, nil, %{"component" => "svc-a"})

    observe(a, "negated", "2026-01-10T06:00:00Z", @t0, nil, %{
      "component" => "svc-a",
      "origin" => "hardware"
    })

    assert classes(a) == [{"linked", "change_related"}]
  end
end
