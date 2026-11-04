defmodule ForecastLoopWeb.PagesTest do
  use ForecastLoopWeb.ConnCase, async: false
  use Oban.Testing, repo: ForecastLoop.Repo

  import Phoenix.LiveViewTest
  import ForecastLoop.Fixtures

  alias ForecastLoop.{Batch, Knowledge, Ledger, Repo}
  alias ForecastLoop.Batch.Gaps

  @t0 "2026-01-01T00:00:00Z"

  test "every page renders, with the attribution footer", %{conn: conn} do
    for path <- ~w(/queue /questions /calibration /signals /knowledge /packs /runs) do
      {:ok, _view, html} = live(conn, path)
      assert html =~ "Peter Rothman", path
    end
  end

  describe "queue" do
    test "groups gaps first and asserts a fact inline that closes the gap on recheck", %{
      conn: conn
    } do
      s =
        signal(%{
          name: "alerts",
          kind: "events",
          source_spec: %{"system" => "csv", "entity_attributes" => ["component"]}
        })

      observe(s, "1", "2026-01-10T00:00:00Z", @t0, nil, %{"component" => "svc-new"})
      Batch.set_as_of(ts("2026-06-01T00:00:00Z"))
      Gaps.run(nil)
      Batch.open_work_item("stale_forecast", "question_agent", "1:2", %{}, nil)

      {:ok, view, html} = live(conn, "/queue")
      [first_kind | _] = Regex.scan(~r/id="kind-([a-z_]+)"/, html) |> Enum.map(&List.last/1)
      assert first_kind == "gap"

      [item] =
        Batch.list_work_items(kind: "gap")
        |> Enum.filter(&(&1.subject_type == "gap_unknown_entity"))

      assert has_element?(view, "#assert-#{item.id}")

      view
      |> form("#assert-#{item.id}", %{
        "predicate" => "entity_domain",
        "subject" => "svc-new",
        "object" => "ops"
      })
      |> render_submit()

      assert [%{object: "ops"}] = Knowledge.list_facts(predicate: "entity_domain")
      html = view |> element("button", "Recheck gaps") |> render_click()
      refute html =~ "id=\"item-#{item.id}\""
    end

    test "dismisses an item and queues a batch run", %{conn: conn} do
      Batch.open_work_item("needs_rethink", "scenario", "9", %{"title" => "S"}, nil)
      [item] = Batch.list_work_items()
      {:ok, view, _} = live(conn, "/queue")
      view |> element("#item-#{item.id} button", "Dismiss") |> render_click()
      assert Batch.list_work_items() == []

      view |> element("button", "Run batch now") |> render_click()
      assert_enqueued(worker: ForecastLoop.Batch.NightlyWorker)
    end
  end

  describe "questions" do
    test "creates a question with all FIP fields and refuses one without", %{conn: conn} do
      {:ok, view, _} = live(conn, "/questions")

      html =
        view
        |> form("#new-question", %{
          "title" => "T",
          "event_definition" => "",
          "resolution_condition" => ~s({"type":"manual"}),
          "deadline" => "2027-01-01T00:00:00Z",
          "domain" => "d",
          "author" => "alice"
        })
        |> render_submit()

      assert html =~ "event_definition is a required Forecast Integrity Protocol field"

      {:error, {:live_redirect, %{to: "/questions/" <> id}}} =
        view
        |> form("#new-question", %{
          "title" => "T",
          "event_definition" => "E",
          "resolution_condition" => ~s({"type":"manual"}),
          "deadline" => "2027-01-01T00:00:00Z",
          "domain" => "d",
          "author" => "alice"
        })
        |> render_submit()

      assert Ledger.get_question!(String.to_integer(id)).status == "review"
    end

    test "review refuses the author; forecast entry records a forecast with cited signals", %{
      conn: conn
    } do
      author = agent("alice")
      q = question(author)
      s = signal(%{name: "level"})
      {:ok, view, _} = live(conn, "/questions/#{q.id}")

      assert view |> form("#review", %{"reviewer" => "alice"}) |> render_submit() =~
               "must not be the author"

      assert view |> form("#review", %{"reviewer" => "bob"}) |> render_submit() =~ "bob"

      q = Ledger.get_question!(q.id) |> Ecto.Changeset.change(status: "live") |> Repo.update!()
      {:ok, view, _} = live(conn, "/questions/#{q.id}")
      assert view |> form("#forecast", %{"probability" => "35"}) |> render_change() =~ "35%"

      html =
        view
        |> form("#forecast", %{
          "probability" => "35",
          "rationale" => "Trend is flat.",
          "agent" => "carol",
          "cited" => [to_string(s.id)]
        })
        |> render_submit()

      assert html =~ "Trend is flat."
      [f] = Ledger.get_question_with_history!(q.id).forecasts
      assert f.probability == 0.35 and f.cited_signal_ids == [s.id]
    end

    test "a resolved question shows its outcome and evidence", %{conn: conn} do
      q = live_question(agent())
      forecast(q, agent("m"), 0.2, "2026-01-02T00:00:00Z")

      {:ok, _} =
        Ledger.resolve_question(q, %{
          outcome: true,
          resolved_at: ts("2026-02-01T00:00:00Z"),
          source: "rule",
          evidence: %{"statistic" => 4.6},
          resolved_by: "batch",
          asserted_by: "t"
        })

      {:ok, view, html} = live(conn, "/questions/#{q.id}")
      assert html =~ "Outcome: TRUE" and html =~ "4.6" and html =~ "history-m"
      assert has_element?(view, "#condition-text", "A person resolves")
      assert has_element?(view, "#result-m", "said 20% TRUE, so it leaned the wrong way")
      assert has_element?(view, "#result-m", "Brier score 0.64")
    end

    test "a resolved series question explains the value used and its inputs", %{conn: conn} do
      s = signal(%{name: "level", cadence: "monthly", units: "points"})
      observe(s, "a", "2026-01-01T00:00:00Z", "2026-01-15T00:00:00Z", 7.0)

      q =
        live_question(agent(), %{
          resolution_condition:
            series_rc(s, ">", 5, "2026-01-01T00:00:00Z", "2026-02-01T00:00:00Z")
        })

      {:ok, _} =
        Ledger.resolve_question(q, %{
          outcome: true,
          resolved_at: ts("2026-03-01T00:00:00Z"),
          source: "rule",
          evidence: %{
            "as_of" => "2026-03-01T00:00:00+00:00",
            "window_from" => "2026-01-01T00:00:00+00:00",
            "window_to" => "2026-02-01T00:00:00+00:00",
            "end_effective_at" => "2026-01-01T00:00:00+00:00",
            "statistic" => 7.0
          },
          resolved_by: "batch",
          asserted_by: "t"
        })

      {:ok, view, _html} = live(conn, "/questions/#{q.id}")

      assert has_element?(
               view,
               "#condition-text",
               "TRUE if the last value of level (in points) in the month 2026-01"
             )

      assert has_element?(
               view,
               "#value-used",
               "The value used is 7, the value of level for 2026-01"
             )

      assert has_element?(view, "#evidence-inputs", "2026-01")
      assert has_element?(view, "#result-summary", "No forecast was made before the resolution")
    end
  end

  test "calibration shows scores, decomposition and a reliability diagram", %{conn: conn} do
    a = agent("A")

    for {p, o, i} <- [{0.9, true, 1}, {0.2, false, 2}, {0.7, false, 3}] do
      q = live_question(agent(), %{domain: "d"})
      forecast(q, a, p, "2026-01-01T00:00:00Z")
      resolve(q, o, "2026-02-0#{i}T00:00:00Z")
    end

    Batch.set_as_of(ts("2026-06-01T00:00:00Z"))
    {:ok, _view, html} = live(conn, "/calibration")
    assert html =~ "Mean Brier" and html =~ "Reliability" and html =~ "reliability diagram"
    assert html =~ ~r/A.*\(human\).*d/s
  end

  test "signals show a sparkline and regime shifts", %{conn: conn} do
    s = signal(%{name: "level", domain: "d"})
    for m <- 1..9, do: observe(s, "2026-0#{m}", "2026-0#{m}-01T00:00:00Z", @t0, m * 1.0)

    Repo.insert!(%ForecastLoop.Signals.RegimeShift{
      signal_id: s.id,
      effective_at: ts("2026-05-01T00:00:00Z"),
      statistic: 3.0,
      p_value: 0.01,
      asserted_by: "t"
    })

    Batch.set_as_of(ts("2026-12-01T00:00:00Z"))
    {:ok, _view, html} = live(conn, "/signals")
    assert html =~ "polyline" and html =~ "regime shift" and html =~ "Regime shifts: 2026-05-01"
  end

  test "knowledge: add, edit validity inline, delete", %{conn: conn} do
    {:ok, view, _} = live(conn, "/knowledge")

    view
    |> form("#add-fact", %{
      "predicate" => "value_alias",
      "subject" => "level:L0",
      "object" => "critical"
    })
    |> render_submit()

    [f] = Knowledge.list_facts()
    view |> element("#fact-#{f.id} button", "Edit") |> render_click()
    view |> form("#edit-#{f.id}", %{"valid_to" => "2026-03-01"}) |> render_submit()
    assert Knowledge.get_fact!(f.id).valid_to == ~U[2026-03-01 00:00:00.000000Z]
    view |> element("#fact-#{f.id} button", "Delete") |> render_click()
    assert Knowledge.list_facts() == []
  end

  test "packs: install a folder, then build a pack in the app", %{conn: conn} do
    {:ok, view, _} = live(conn, "/packs")

    assert view |> element("#available button[phx-value-name=regional_economy]") |> render_click() =~
             "Installed regional_economy"

    {:error, {:live_redirect, %{to: "/packs/mine"}}} =
      view
      |> form("#new-pack", %{"name" => "mine", "title" => "Mine", "description" => "x"})
      |> render_submit()

    {:ok, view, _} = live(conn, "/packs/mine")

    spec =
      Jason.encode!(%{
        "system" => "csv",
        "path" => "test/fixtures/sources/monthly_v1.csv",
        "fields" => %{"effective_at" => "DATE", "value" => "VALUE"}
      })

    assert view |> form("#preview", %{"source_spec" => spec}) |> render_submit() =~ "4 rows"

    view
    |> form("#add-signal", %{
      "name" => "my_level",
      "kind" => "series",
      "domain" => "mine",
      "source_spec" => spec
    })
    |> render_submit()

    assert ForecastLoop.Signals.get_by_name("my_level").pack == "mine"

    view
    |> form("#add-scenario", %{"title" => "Flat", "assumptions" => "A\nB"})
    |> render_submit()

    assert render(view) =~ "Flat (2 assumptions)"

    assert view |> element("button", "Export to folder") |> render_click() =~ "Exported to"
  end

  test "runs list step counts and queue a run", %{conn: conn} do
    Repo.insert!(%ForecastLoop.Batch.Run{
      started_at: ts(@t0),
      as_of: ts(@t0),
      status: "succeeded",
      stats: %{"refresh" => %{"appended" => 3}},
      asserted_by: "t"
    })

    {:ok, view, html} = live(conn, "/runs")
    assert html =~ "appended 3"
    view |> element("button", "Run batch now") |> render_click()
    assert_enqueued(worker: ForecastLoop.Batch.NightlyWorker)
  end
end
