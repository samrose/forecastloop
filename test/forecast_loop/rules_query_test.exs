defmodule ForecastLoop.RulesQueryTest do
  use ForecastLoop.DataCase, async: true

  alias ForecastLoop.Rules

  test "reads rule views and returns the SQL with the rows" do
    question(agent(), %{domain: "q_domain"})

    assert {:ok, %{columns: ["subject_id", "detail"], rows: [["q_domain", _]], sql: sql}} =
             Rules.query("SELECT * FROM gap_unowned_domain")

    assert sql =~ "gap_unowned_domain"
  end

  test "views that read observations through observations_as_of work" do
    assert {:ok, %{rows: []}} = Rules.query("SELECT * FROM k_observation_normalized")
  end

  test "cannot read other tables or write" do
    assert {:error, msg} = Rules.query("SELECT * FROM public.agents")
    assert msg =~ "permission denied"
    assert {:error, msg} = Rules.query("DELETE FROM public.knowledge_facts")
    assert msg =~ "read-only" or msg =~ "permission denied"
  end

  test "a statement timeout stops a slow query" do
    assert {:error, msg} = Rules.query("SELECT pg_sleep(2)", timeout_ms: 100)
    assert msg =~ "statement timeout"
  end
end
