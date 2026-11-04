defmodule ForecastLoop.LoopTest do
  use ForecastLoop.DataCase, async: false

  alias ForecastLoop.{Batch, Ledger, Rules}
  alias ForecastLoop.Batch.{Act, Templates}
  alias ForecastLoop.Ledger.QuestionTemplate

  @t0 "2026-01-01T00:00:00Z"

  defp status(q),
    do: Rules.rows("loop_condition_status") |> Enum.find(&(&1["question_id"] == q.id))

  defp resolvable(q), do: Rules.rows("loop_resolvable") |> Enum.find(&(&1["question_id"] == q.id))

  defp monthly(values, observed_at \\ @t0) do
    s = signal(%{cadence: "monthly"})

    for {v, m} <- Enum.with_index(values, 1) do
      mm = String.pad_leading("#{m}", 2, "0")
      observe(s, "2026-#{mm}", "2026-#{mm}-01T00:00:00Z", observed_at, v)
    end

    s
  end

  describe "going live" do
    test "loop_live_question lists a reviewed question and the act step promotes it" do
      author = agent()
      q = question(author)
      assert Rules.rows("loop_live_question") == []
      {:ok, _} = Ledger.review_question(q, agent(), "t")
      assert [%{"question_id" => id}] = Rules.rows("loop_live_question")
      assert id == q.id

      Batch.set_as_of(ts("2026-06-01T00:00:00Z"))
      assert %{"promoted" => 1} = Act.run(nil, ts("2026-06-01T00:00:00Z"))
      assert Ledger.get_question!(q.id).status == "live"
    end

    test "a self-reviewed question is not listed and cannot go live" do
      author = agent()
      {:ok, _} = Ledger.review_question(question(author), author, "t")
      assert Rules.rows("loop_live_question") == []
    end
  end

  describe "series conditions" do
    test "end_of_window waits for the last period, then resolves" do
      s = monthly([4.0, 4.2, 4.6])

      q =
        live_question(agent(), %{
          resolution_condition:
            series_rc(s, ">=", 4.5, "2026-01-01T00:00:00Z", "2026-04-01T00:00:00Z")
        })

      Batch.set_as_of(ts("2026-03-15T00:00:00Z"))
      assert %{"determined" => false} = status(q)

      Batch.set_as_of(ts("2026-04-02T00:00:00Z"))
      assert %{"determined" => true, "outcome" => true, "statistic" => 4.6} = status(q)
      assert %{"outcome" => true, "reason" => "threshold_crossed"} = resolvable(q)
    end

    test "end_of_window after the deadline without the last period's data awaits data" do
      s = monthly([4.0, 4.2])

      q =
        live_question(agent(), %{
          deadline: ts("2026-04-01T00:00:00Z"),
          resolution_condition:
            series_rc(s, ">=", 4.5, "2026-01-01T00:00:00Z", "2026-04-01T00:00:00Z")
        })

      Batch.set_as_of(ts("2026-04-10T00:00:00Z"))
      assert %{"outcome" => nil, "reason" => "awaiting_data"} = resolvable(q)

      assert %{"awaiting_resolution" => 1} = Act.run(nil, ts("2026-04-10T00:00:00Z"))

      assert [%{kind: "needs_resolution", payload: %{"reason" => "awaiting_data"}}] =
               Batch.list_work_items(kind: "needs_resolution")
    end

    test "end_of_window that misses the threshold resolves false" do
      s = monthly([4.0, 4.2, 4.3])

      q =
        live_question(agent(), %{
          resolution_condition:
            series_rc(s, ">=", 4.5, "2026-01-01T00:00:00Z", "2026-04-01T00:00:00Z")
        })

      Batch.set_as_of(ts("2026-04-02T00:00:00Z"))
      assert %{"outcome" => false, "reason" => "condition_determined"} = resolvable(q)
    end

    test "any_in_window resolves true early" do
      s = monthly([4.0, 4.7])

      q =
        live_question(agent(), %{
          resolution_condition:
            series_rc(
              s,
              ">",
              4.5,
              "2026-01-01T00:00:00Z",
              "2026-12-01T00:00:00Z",
              "any_in_window"
            )
        })

      Batch.set_as_of(ts("2026-03-01T00:00:00Z"))
      assert %{"outcome" => true} = resolvable(q)
    end

    test "mean_in_window" do
      s = monthly([4.0, 5.0, 6.0])

      q =
        live_question(agent(), %{
          resolution_condition:
            series_rc(
              s,
              ">=",
              5.0,
              "2026-01-01T00:00:00Z",
              "2026-04-01T00:00:00Z",
              "mean_in_window"
            )
        })

      Batch.set_as_of(ts("2026-04-02T00:00:00Z"))
      assert %{"statistic" => 5.0, "outcome" => true} = status(q)
    end
  end

  describe "events conditions" do
    setup do
      e = signal(%{kind: "events", source_spec: %{"system" => "csv"}})
      observe(e, "a", "2026-02-01T00:00:00Z", @t0, nil, %{"kind" => "x"})
      observe(e, "b", "2026-02-05T00:00:00Z", @t0, nil, %{"kind" => "y"})
      observe(e, "c", "2026-02-09T00:00:00Z", @t0, nil, %{"kind" => "x"})
      %{e: e}
    end

    test "count>= resolves true as soon as it is reached, with the where filter", %{e: e} do
      q =
        live_question(agent(), %{
          resolution_condition:
            events_rc(e, "count>=", 2, "2026-01-01T00:00:00Z", "2026-12-01T00:00:00Z", %{
              "kind" => "x"
            })
        })

      Batch.set_as_of(ts("2026-03-01T00:00:00Z"))

      assert %{"outcome" => true, "evidence" => %{"events" => 2, "records" => ["a", "c"]}} =
               resolvable(q)
    end

    test "count<= is determined false as soon as it is exceeded", %{e: e} do
      q =
        live_question(agent(), %{
          resolution_condition:
            events_rc(e, "count<=", 1, "2026-01-01T00:00:00Z", "2026-12-01T00:00:00Z")
        })

      Batch.set_as_of(ts("2026-03-01T00:00:00Z"))
      assert %{"outcome" => false, "reason" => "condition_determined"} = resolvable(q)
    end

    test "where.class uses k_event_class", %{e: e} do
      {:ok, _} =
        ForecastLoop.Knowledge.assert_fact(%{
          predicate: "class_rule",
          subject: "kind",
          object: "special",
          attributes: %{"equals" => "y"},
          asserted_by: "t"
        })

      q =
        live_question(agent(), %{
          resolution_condition:
            events_rc(e, "count>=", 1, "2026-01-01T00:00:00Z", "2026-12-01T00:00:00Z", %{
              "class" => "special"
            })
        })

      Batch.set_as_of(ts("2026-03-01T00:00:00Z"))
      assert %{"evidence" => %{"records" => ["b"]}} = resolvable(q)
    end
  end

  test "a manual question past its deadline opens needs_resolution; resolving closes it" do
    q = live_question(agent(), %{deadline: ts("2026-02-01T00:00:00Z")})
    Batch.set_as_of(ts("2026-03-01T00:00:00Z"))
    assert %{"outcome" => nil, "reason" => "manual"} = resolvable(q)
    Act.run(nil, ts("2026-03-01T00:00:00Z"))
    assert [_] = Batch.list_work_items(kind: "needs_resolution")

    resolve(Ledger.get_question!(q.id), true, "2026-03-02T00:00:00Z")
    Act.run(nil, ts("2026-03-03T00:00:00Z"))
    assert Batch.list_work_items(kind: "needs_resolution") == []
  end

  test "the act step resolves with evidence and scores the forecasts" do
    s = monthly([4.0, 4.2, 4.6])
    forecaster = agent()

    q =
      live_question(agent(), %{
        resolution_condition:
          series_rc(s, ">=", 4.5, "2026-01-01T00:00:00Z", "2026-04-01T00:00:00Z")
      })

    forecast(q, forecaster, 0.7, "2026-01-02T00:00:00Z")
    Batch.set_as_of(ts("2026-04-02T00:00:00Z"))

    assert %{"resolved" => 1, "scores" => %{"upserted" => 1}} =
             Act.run(nil, ts("2026-04-02T00:00:00Z"))

    q = Ledger.get_question_with_history!(q.id)
    assert q.status == "resolved"
    assert q.resolution.outcome and q.resolution.evidence["statistic"] == 4.6
    assert [%{brier: b}] = Repo.all(ForecastLoop.Ledger.Score)
    assert_in_delta b, 0.09, 1.0e-12
  end

  describe "stale forecasts" do
    test "a cited signal that moves past the threshold opens stale_forecast after one run" do
      s = monthly(Enum.map(1..12, &(4.0 + rem(&1, 3) * 0.1)))
      forecaster = agent()

      q =
        live_question(agent(), %{
          resolution_condition:
            series_rc(s, ">=", 5.0, "2026-12-01T00:00:00Z", "2027-01-01T00:00:00Z")
        })

      forecast(q, forecaster, 0.2, "2026-12-05T00:00:00Z")
      Batch.set_as_of(ts("2026-12-20T00:00:00Z"))
      Act.run(nil, ts("2026-12-20T00:00:00Z"))
      assert Batch.list_work_items(kind: "stale_forecast") == []

      # December was 4.0 at forecast time. A move of 0.01 is below 10% of the trailing range 0.2.
      observe(s, "2026-12", "2026-12-01T00:00:00Z", "2026-12-21T00:00:00Z", 4.01)
      Batch.set_as_of(ts("2026-12-22T00:00:00Z"))
      Act.run(nil, ts("2026-12-22T00:00:00Z"))
      assert Batch.list_work_items(kind: "stale_forecast") == []

      observe(s, "2026-12", "2026-12-01T00:00:00Z", "2026-12-23T00:00:00Z", 4.9)
      Batch.set_as_of(ts("2026-12-24T00:00:00Z"))
      Act.run(nil, ts("2026-12-24T00:00:00Z"))

      assert [%{subject_id: sid, payload: %{"signals" => [%{"now" => 4.9}]}}] =
               Batch.list_work_items(kind: "stale_forecast")

      assert sid == "#{q.id}:#{forecaster.id}"

      # A new forecast clears it on the next run.
      forecast(q, forecaster, 0.6, "2026-12-24T01:00:00Z")
      Batch.set_as_of(ts("2026-12-25T00:00:00Z"))
      Act.run(nil, ts("2026-12-25T00:00:00Z"))
      assert Batch.list_work_items(kind: "stale_forecast") == []
    end
  end

  describe "templates" do
    setup do
      s = signal(%{name: "level_series", cadence: "monthly"})
      author = agent()

      {:ok, t} =
        Ledger.create_template(%{
          key: "level_q",
          domain: "test_domain",
          title_pattern: "Level above {{param.x}} at end of {{period}}?",
          event_definition_pattern:
            "The last value of level_series in {{period}} ({{period_start}} to {{period_end}}) is >= {{param.x}}.",
          resolution_condition_pattern: %{
            "type" => "series",
            "signal" => "level_series",
            "op" => ">=",
            "value" => "{{param.x}}",
            "at" => "end_of_window"
          },
          cadence: "quarterly",
          window_length: "P3M",
          params: %{"x" => 4.5},
          starts_on: ~D[2026-01-01],
          created_by_id: author.id,
          asserted_by: "t"
        })

      %{s: s, t: t, author: author}
    end

    test "the next period's question is made once, in review, fully rendered", %{
      s: s,
      t: t,
      author: author
    } do
      Batch.set_as_of(ts("2026-11-03T00:00:00Z"))
      assert %{"created" => 1} = Templates.run(nil)
      assert %{"created" => 0} = Templates.run(nil)

      [q] = Ledger.list_questions()
      assert q.status == "review" and q.template_id == t.id and q.template_period == "2027-Q1"
      assert q.title == "Level above 4.5 at end of 2027-Q1?"
      assert q.event_definition =~ "2027-01-01T00:00:00Z to 2027-04-01T00:00:00Z"
      assert q.deadline == ~U[2027-04-01 00:00:00.000000Z]
      assert q.created_by_id == author.id

      assert q.resolution_condition == %{
               "type" => "series",
               "signal_id" => s.id,
               "op" => ">=",
               "value" => 4.5,
               "at" => "end_of_window",
               "window" => %{"from" => "2027-01-01T00:00:00Z", "to" => "2027-04-01T00:00:00Z"}
             }
    end

    test "an unknown signal name blocks the template with a work item", %{t: t} do
      {:ok, _} =
        t
        |> QuestionTemplate.changeset(%{
          resolution_condition_pattern: %{t.resolution_condition_pattern | "signal" => "nope"}
        })
        |> Repo.update()

      Batch.set_as_of(ts("2026-11-03T00:00:00Z"))
      assert %{"created" => 0, "blocked" => 1} = Templates.run(nil)

      assert [%{kind: "template_blocked", payload: %{"problem" => "unknown_signal:nope"}}] =
               Batch.list_work_items(kind: "template_blocked")
    end
  end

  test "underspecified drafts and falsified scenario assumptions open work items" do
    {:ok, _draft} =
      Ledger.create_draft_question(%{title: "Rough", created_by_id: agent().id, asserted_by: "t"})

    q = live_question(agent())
    {:ok, sc} = Ledger.create_scenario(%{title: "S", asserted_by: "t"})

    {:ok, _} =
      Ledger.create_assumption(%{
        scenario_id: sc.id,
        statement: "A holds",
        question_id: q.id,
        asserted_by: "t"
      })

    resolve(q, false, "2026-02-01T00:00:00Z")

    Batch.set_as_of(ts("2026-03-01T00:00:00Z"))
    stats = Act.run(nil, ts("2026-03-01T00:00:00Z"))
    assert stats["work_items_opened"]["underspecified_question"] == 1

    assert [
             %{
               payload: %{
                 "missing" => ["event_definition", "resolution_condition", "deadline", "domain"]
               }
             }
           ] =
             Batch.list_work_items(kind: "underspecified_question")

    assert [%{subject_id: sid}] = Batch.list_work_items(kind: "needs_rethink")
    assert sid == to_string(sc.id)
  end
end
