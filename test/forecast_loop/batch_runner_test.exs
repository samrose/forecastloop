defmodule ForecastLoop.BatchRunnerTest do
  @moduledoc "The whole batch: idempotency and the knowledge snapshot."
  use ForecastLoop.DataCase, async: false

  alias ForecastLoop.Batch.{Runner, Snapshot}
  alias ForecastLoop.{Knowledge, Ledger, Signals}

  @moduletag :tmp_dir

  # The refresh step stamps rows with the real fetch time, so a run must be as of a
  # time after it to see the refreshed data.
  defp as_of, do: DateTime.utc_now() |> DateTime.add(1, :day)

  # Every application table except the run bookkeeping.
  @tables ~w(agents scenarios assumptions question_templates questions model_versions forecasts
             resolutions scores signals observations regime_shifts knowledge_facts packs work_items config)

  defp dump do
    Map.new(@tables, fn t ->
      %{rows: rows} =
        Repo.query!(
          "SELECT to_jsonb(x) - 'run_id' FROM \"#{t}\" x ORDER BY (to_jsonb(x) - 'run_id')::text"
        )

      {t, rows}
    end)
  end

  setup %{tmp_dir: dir} do
    path = Path.join(dir, "level.csv")

    rows =
      for i <- 0..29,
          do:
            "#{Date.shift(~D[2024-01-01], month: i)},#{if i < 18, do: 4.0 + rem(i, 3) * 0.1, else: 6.0 + rem(i, 3) * 0.1}"

    File.write!(path, "DATE,VALUE\n" <> Enum.join(rows, "\n") <> "\n")

    {:ok, s} =
      Signals.register_signal(%{
        name: "level",
        domain: "test_domain",
        kind: "series",
        cadence: "monthly",
        source_spec: %{
          "system" => "csv",
          "path" => path,
          "fields" => %{"effective_at" => "DATE", "value" => "VALUE"}
        },
        asserted_by: "t"
      })

    {:ok, _} =
      Signals.register_signal(%{
        name: "level_change",
        domain: "test_domain",
        kind: "derived",
        source_spec: %{
          "system" => "derived",
          "operation" => "change_over_periods",
          "signal" => "level",
          "lag" => 1
        },
        asserted_by: "t"
      })

    {:ok, _} =
      Knowledge.assert_fact(%{
        predicate: "min_history",
        subject: "test_domain",
        object: "12",
        asserted_by: "t"
      })

    author = agent()

    {:ok, _} =
      Ledger.create_template(%{
        key: "level_q",
        domain: "test_domain",
        title_pattern: "Level >= 6 at end of {{period}}?",
        event_definition_pattern: "x",
        resolution_condition_pattern: %{
          "type" => "series",
          "signal" => "level",
          "op" => ">=",
          "value" => 6.0,
          "at" => "end_of_window"
        },
        cadence: "quarterly",
        window_length: "P3M",
        starts_on: ~D[2024-01-01],
        created_by_id: author.id,
        asserted_by: "t"
      })

    {:ok, ma} = Ledger.ensure_agent("model:st", "model")

    {:ok, _} =
      Ledger.create_model_version(%{
        agent_id: ma.id,
        model_module: "ForecastLoop.Models.SeriesThreshold",
        version: "1",
        domains: ["test_domain"],
        asserted_by: "t"
      })

    # A live question that resolves in this run.
    q =
      live_question(author, %{
        resolution_condition:
          series_rc(s, ">=", 5.0, "2025-04-01T00:00:00Z", "2025-07-01T00:00:00Z")
      })

    forecast(q, agent(), 0.4, "2025-03-01T00:00:00Z")
    :ok
  end

  test "running the batch twice on the same data changes nothing but runs" do
    as_of = as_of()
    assert {:ok, run1} = Runner.run(as_of: as_of)
    assert run1.status == "succeeded"
    s = run1.stats
    assert s["refresh"]["appended"] == 30
    assert s["derive"]["appended"] == 29
    assert s["templates"]["created"] == 1
    assert s["act"]["resolved"] == 1
    assert s["changepoints"]["inserted"] >= 1
    first = dump()

    assert {:ok, run2} = Runner.run(as_of: as_of)
    assert run2.stats["refresh"]["appended"] == 0
    assert run2.stats["act"]["resolved"] == 0
    assert dump() == first
    assert Repo.aggregate(ForecastLoop.Batch.Run, :count) == 2
  end

  test "each run writes a knowledge snapshot of every k_ view, identical on the same data" do
    as_of = as_of()
    # The snapshot (step 3) comes before derive (step 4), so the first run's snapshot
    # lacks the derived observations that the run then adds. Runs 2 and 3 see the same data.
    {:ok, _r0} = Runner.run(as_of: as_of)
    {:ok, r1} = Runner.run(as_of: as_of)
    {:ok, r2} = Runner.run(as_of: as_of)
    files = File.ls!(Snapshot.dir(r1.id)) |> Enum.sort()
    assert files == ForecastLoop.Rules.views("k") |> Enum.map(&(&1 <> ".csv"))

    for f <- files do
      assert File.read!(Path.join(Snapshot.dir(r1.id), f)) ==
               File.read!(Path.join(Snapshot.dir(r2.id), f))
    end

    assert File.read!(Path.join(Snapshot.dir(r1.id), "k_observation_normalized.csv")) =~
             "observation_id,signal_id"
  end

  @tag :capture_log
  test "a failing step marks the run failed and keeps earlier steps' stats" do
    Repo.query!("DROP VIEW rules.loop_template_due CASCADE")
    assert {:error, run} = Runner.run(as_of: as_of())
    assert run.status == "failed"
    assert run.stats["templates"]["error"] =~ "loop_template_due"
    assert run.stats["refresh"]["appended"] == 30
  end
end
