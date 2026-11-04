defmodule ForecastLoop.KnowledgeTest do
  use ForecastLoop.DataCase, async: true

  alias ForecastLoop.Knowledge
  alias ForecastLoop.Knowledge.Fact

  test "imports a CSV idempotently" do
    assert {:ok, 6} = Knowledge.import_csv("test/fixtures/knowledge/facts.csv", pack: "test_pack")
    before = Repo.all(from(f in Fact, order_by: f.id))
    assert length(before) == 6
    assert Enum.all?(before, &(&1.pack == "test_pack"))

    assert {:ok, 6} = Knowledge.import_csv("test/fixtures/knowledge/facts.csv", pack: "test_pack")
    assert Repo.all(from(f in Fact, order_by: f.id)) == before

    alias_fact = Enum.find(before, &(&1.predicate == "value_alias"))
    assert alias_fact.valid_to == ~U[2026-03-01 00:00:00.000000Z]

    assert Enum.find(before, &(&1.predicate == "class_rule")).attributes == %{
             "equals" => "change",
             "negates" => ["hardware"]
           }
  end

  test "a changed row updates the fact with the same identity" do
    {:ok, f} =
      Knowledge.assert_fact(%{
        predicate: "entity_attr",
        subject: "a",
        object: "team=b",
        asserted_by: "t"
      })

    {:ok, f2} =
      Knowledge.assert_fact(%{
        predicate: "entity_attr",
        subject: "a",
        object: "team=b",
        note: "why",
        asserted_by: "t"
      })

    assert f2.id == f.id
    assert f2.note == "why"
  end

  test "a bad row imports nothing and reports its line" do
    assert {:error, {3, %{predicate: [_]}}} =
             Knowledge.import_csv("test/fixtures/knowledge/bad.csv")

    assert Repo.aggregate(Fact, :count) == 0
  end
end
