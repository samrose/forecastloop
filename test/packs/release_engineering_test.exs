defmodule ForecastLoop.Packs.ReleaseEngineeringTest do
  @moduledoc """
  Acceptance for the release_engineering pack:

  * an event from an entity with no entity_attr opens gap_unknown_entity; asserting
    the fact closes it and the event is classified on the next run;
  * narrowing a value_alias valid_to reclassifies only events in the affected range.
  """
  use ForecastLoop.DataCase, async: false

  import ForecastLoop.PackFixtures

  alias ForecastLoop.{Batch, Knowledge, Packs, Rules}
  alias ForecastLoop.Batch.Runner
  alias ForecastLoop.Knowledge.Fact

  @moduletag :capture_log
  @as_of "2026-04-25T00:00:00Z"

  setup do
    System.put_env("INCIDENT_IO_API_KEY", "test-key")
    System.put_env("GITHUB_TOKEN", "test-token")
    serve_release_engineering_fixtures()

    on_exit(fn ->
      System.delete_env("INCIDENT_IO_API_KEY")
      System.delete_env("GITHUB_TOKEN")
    end)

    {:ok, _} = Packs.install("release_engineering")
    {:ok, run} = Runner.run(as_of: ts(@as_of))
    %{run: run}
  end

  defp run_again, do: Runner.run(as_of: ts(@as_of), refresh: false)

  # source_record_id => sorted classes, for incidents.
  defp classes do
    Batch.set_as_of(ts(@as_of))

    ids =
      Map.new(
        Rules.rows("k_observation_normalized"),
        &{&1["observation_id"], &1["source_record_id"]}
      )

    Rules.rows("k_event_class")
    |> Enum.group_by(&ids[&1["observation_id"]], & &1["class"])
    |> Map.new(fn {k, v} -> {k, v |> Enum.uniq() |> Enum.sort()} end)
  end

  defp severities do
    Batch.set_as_of(ts(@as_of))

    Rules.rows("k_observation_normalized")
    |> Enum.filter(&(&1["signal_name"] == "incidents"))
    |> Map.new(&{&1["source_record_id"], &1["attributes"]["severity"]})
  end

  defp domain_of(record_id) do
    Batch.set_as_of(ts(@as_of))

    [obs] =
      Rules.rows("k_observation_normalized")
      |> Enum.filter(&(&1["source_record_id"] == record_id))

    Rules.rows("k_event_domain")
    |> Enum.filter(&(&1["observation_id"] == obs["observation_id"]))
    |> Enum.map(& &1["domain"])
  end

  defp open_gaps(view),
    do:
      Batch.list_work_items(kind: "gap")
      |> Enum.filter(&(&1.subject_type == view))
      |> Enum.map(& &1.subject_id)
      |> Enum.sort()

  test "the batch ingests, classifies by cause and by link, and respects negation", %{run: run} do
    assert run.status == "succeeded"
    assert run.stats["refresh"]["appended"] == 6 + 8

    assert classes() == %{
             "01HQ0001" => ["release_related"],
             "01HQ0003" => ["release_related"],
             "01HQ0005" => ["release_related"]
           }

    # 01HQ0002 (hardware) and 01HQ0006 (third-party) are explicitly negative, so only 01HQ0004 is a gap.
    assert open_gaps("gap_unclassified_event") |> length() == 1
  end

  test "an unknown entity opens a gap; asserting facts closes it and classifies the event on the next run" do
    assert open_gaps("gap_unknown_entity") == ["acme/payments", "payments-api"]

    assert domain_of("01HQ0004") == ["release_engineering"],
           "before: only the signal's fallback domain"

    refute Map.has_key?(classes(), "01HQ0004")

    # The repository deploys payments-api: now the deploy links to the incident.
    {:ok, _} =
      Knowledge.assert_fact(%{
        predicate: "entity_alias",
        subject: "acme/payments",
        object: "payments-api",
        asserted_by: "person"
      })

    {:ok, _} = run_again()
    assert classes()["01HQ0004"] == ["release_related"]
    assert open_gaps("gap_unclassified_event") == []
    assert open_gaps("gap_unknown_entity") == ["payments-api"]

    # The entity_attr fact closes the last gap; the event reaches its domain through the owner.
    {:ok, _} =
      Knowledge.assert_fact(%{
        predicate: "entity_attr",
        subject: "payments-api",
        object: "owner=release-eng",
        asserted_by: "person"
      })

    {:ok, _} = run_again()
    assert open_gaps("gap_unknown_entity") == []

    Batch.set_as_of(ts(@as_of))

    [obs] =
      Rules.rows("k_observation_normalized")
      |> Enum.filter(&(&1["source_record_id"] == "01HQ0004"))

    assert [%{"domain" => "release_engineering", "via_entity" => "release-eng"}] =
             Rules.rows("k_event_domain")
             |> Enum.filter(&(&1["observation_id"] == obs["observation_id"]))
  end

  test "narrowing a value_alias valid_to reclassifies only events in the affected range" do
    before = severities()

    assert before == %{
             "01HQ0001" => "sev1",
             "01HQ0002" => "sev3",
             "01HQ0003" => "sev2",
             "01HQ0004" => "sev2",
             "01HQ0005" => "P0",
             "01HQ0006" => "sev1"
           }

    p0 = Repo.get_by!(Fact, predicate: "value_alias", subject: "severity:P0")
    {:ok, _} = Knowledge.update_fact(p0, %{valid_to: ts("2026-01-05T00:00:00Z")})

    after_change = severities()
    changed = for {id, sev} <- after_change, before[id] != sev, do: id
    assert changed == ["01HQ0001"]
    assert after_change["01HQ0001"] == "P0"
  end

  test "derived rates and templates" do
    Batch.set_as_of(ts(@as_of))
    sig = fn name -> ForecastLoop.Signals.get_by_name(name) end

    [q1] =
      ForecastLoop.Observations.as_of(
        [sig.("release_incidents_per_deploy_quarterly").id],
        ts(@as_of)
      )

    # Q1 2026: 3 release-related incidents (01HQ0001, 01HQ0003, 01HQ0005) / 6 deploys.
    assert q1.source_record_id == "2026-Q1" and q1.value == 0.5

    titles =
      ForecastLoop.Ledger.list_questions(status: "review") |> Enum.map(& &1.title) |> Enum.sort()

    assert titles == [
             "At least one sev1 or sev2 release-related incident in 2026-05?",
             "Release-related incidents per deploy in 2026-Q3 below 0.25?"
           ]
  end
end
