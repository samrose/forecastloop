defmodule ForecastLoop.Packs.RegionalEconomyTest do
  @moduledoc """
  Acceptance: with the regional_economy pack alone installed, the full loop runs end
  to end on the recorded FRED CSVs: templates instantiate, series questions
  resolve, scores and calibration populate, and the shift in the unemployment
  series produces a regime shift.
  """
  use ForecastLoop.DataCase, async: false

  import ForecastLoop.PackFixtures

  alias ForecastLoop.{Batch, Ledger, Packs, Rules, Signals}
  alias ForecastLoop.Batch.Runner
  alias ForecastLoop.Ledger.Question
  alias ForecastLoop.Signals.RegimeShift

  @moduletag :capture_log

  setup do
    serve_fred_fixtures("regional_economy")
    {:ok, summary} = Packs.install("regional_economy")
    %{summary: summary}
  end

  test "installing twice changes nothing", %{summary: summary} do
    assert summary["signals_changed"] == 8
    assert summary["templates_changed"] == 2
    assert summary["scenarios_added"] == 2
    assert summary["facts"] == 8

    assert {:ok, again} = Packs.install("regional_economy")
    assert again["signals_changed"] == 0 and again["templates_changed"] == 0
    assert again["models_changed"] == 0 and again["scenarios_added"] == 0

    assert %{
             "signals" => 8,
             "knowledge_facts" => 8,
             "question_templates" => 2,
             "model_versions" => 2,
             "scenarios" => 2
           } =
             Packs.contributions("regional_economy")
  end

  test "the full loop runs end to end on the recorded CSVs" do
    reviewer = agent("reviewer", "human")
    unemployment = Signals.get_by_name("ingham_unemployment_rate")

    # 1. First run: ingest, derive, detect shifts, make the 2026-Q1 questions.
    {:ok, run1} = Runner.run(as_of: ts("2025-12-20T00:00:00Z"))
    assert run1.stats["refresh"]["appended"] > 1000

    assert run1.stats["refresh"]["failed"] == 1,
           "only the BLS file signal fails: its file is not supplied"

    assert [%{kind: "refresh_failed", payload: %{"signal" => "ingham_unemployment_rate_bls"}}] =
             Batch.list_work_items(kind: "refresh_failed")

    assert run1.stats["derive"]["appended"] > 100
    assert run1.stats["templates"]["created"] == 2

    shifts = Repo.all(from(r in RegimeShift, where: r.signal_id == ^unemployment.id))
    assert shifts != []

    assert Enum.any?(shifts, &(&1.effective_at.year in 2020..2021)),
           "the 2020 shift is found: #{inspect(Enum.map(shifts, & &1.effective_at))}"

    questions = Ledger.list_questions(status: "review")
    assert questions |> Enum.map(& &1.template_period) |> Enum.uniq() == ["2026-Q1"]

    for q <- questions do
      assert q.title =~ "2026-Q1"
      {:ok, _} = Ledger.review_question(q, reviewer, "test")
    end

    # 2. Next run: the reviewed questions go live and the pack's models forecast them.
    {:ok, run2} = Runner.run(as_of: ts("2026-01-05T00:00:00Z"), refresh: false)
    assert run2.stats["act"]["promoted"] == 2
    assert run2.stats["act"]["forecasts"]["made"] >= 2

    # 3. After the March data is published, both questions resolve from the data.
    {:ok, run3} = Runner.run(as_of: ts("2026-06-30T00:00:00Z"), refresh: false)
    assert run3.stats["act"]["resolved"] == 2

    resolved =
      Ledger.list_questions(status: "resolved")
      |> Enum.map(&Ledger.get_question_with_history!(&1.id))

    by_key = Map.new(resolved, &{Repo.preload(&1, :template).template.key, &1})

    # March 2026 rate is 4.5, which is not above 4.5.
    unemp = by_key["ingham_unemployment_above"]
    refute unemp.resolution.outcome
    assert unemp.resolution.evidence["statistic"] == 4.5

    # Q1 2026 permits 1238 + 1369 + 1626 = 4233 against 4532 in Q1 2025.
    permits = by_key["mi_permits_beat_prior_year"]
    refute permits.resolution.outcome
    assert permits.resolution.evidence["statistic"] == 4233.0 - 4532.0

    # Scores and calibration populate.
    assert Repo.aggregate(ForecastLoop.Ledger.Score, :count) >= 2
    Batch.set_as_of(ts("2026-06-30T00:00:00Z"))
    summary = Rules.rows("cal_summary")

    assert Enum.any?(
             summary,
             &(&1["domain"] == "regional_economy" and &1["agent_name"] == "model:series_threshold")
           )

    # The next quarter's questions were made on the way.
    assert Repo.exists?(from(q in Question, where: q.template_period == "2026-Q3"))
  end

  test "knowledge links places to the domain; same_as names the canonical publisher" do
    Runner.run(as_of: ts("2025-12-20T00:00:00Z"))
    Batch.set_as_of(ts("2025-12-20T00:00:00Z"))
    assert Rules.rows("gap_unknown_entity") == []
    assert Rules.rows("gap_insufficient_history") == []

    domains = Rules.rows("k_event_domain") |> Enum.map(& &1["domain"]) |> Enum.uniq()
    assert domains == ["regional_economy"]

    canon =
      Rules.rows("k_series_canonical")
      |> Map.new(&{&1["signal_name"], &1["canonical_signal_name"]})

    assert canon == %{
             "ingham_unemployment_rate" => "ingham_unemployment_rate_bls",
             "ingham_unemployment_rate_bls" => "ingham_unemployment_rate_bls"
           }
  end

  @tag :tmp_dir
  test "export writes a folder that installs as an equal pack", %{tmp_dir: dir} do
    :ok = Packs.export("regional_economy", dir)
    assert File.exists?(Path.join(dir, "knowledge/facts.csv"))
    assert {:ok, again} = Packs.install(dir)

    assert again["signals_changed"] == 0 and again["templates_changed"] == 0 and
             again["scenarios_added"] == 0

    assert again["facts"] == 8

    assert [%{title: "Steady labor market in mid-Michigan", assumptions: [_, _]} | _] =
             Packs.parse_scenarios(File.read!(Path.join(dir, "scenarios.md")))
  end
end
