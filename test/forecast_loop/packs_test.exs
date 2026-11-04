defmodule ForecastLoop.PacksTest do
  @moduledoc "The pack mechanism with a pack built in the application (docs/adr/0009)."
  use ForecastLoop.DataCase, async: true

  alias ForecastLoop.{Knowledge, Ledger, Packs, Signals}

  @moduletag :tmp_dir

  test "a pack built in the app exports and reinstalls", %{tmp_dir: dir} do
    {:ok, pack} = Packs.create_pack(%{name: "my_pack", title: "Mine", asserted_by: "person"})
    assert pack.status == "draft" and pack.origin == "builder"

    {:ok, _} =
      Signals.register_signal(%{
        name: "my_series",
        domain: "mine",
        kind: "series",
        pack: "my_pack",
        asserted_by: "person",
        source_spec: %{"system" => "csv", "path" => "x.csv", "fields" => %{"effective_at" => "d"}}
      })

    {:ok, _} =
      Knowledge.assert_fact(%{
        predicate: "min_history",
        subject: "mine",
        object: "10",
        pack: "my_pack",
        asserted_by: "person"
      })

    {:ok, sc} =
      Ledger.create_scenario(%{
        title: "A future",
        narrative: "It goes like this.",
        domain: "mine",
        pack: "my_pack",
        asserted_by: "person"
      })

    {:ok, _} =
      Ledger.create_assumption(%{
        scenario_id: sc.id,
        statement: "X stays low",
        asserted_by: "person"
      })

    assert %{"signals" => 1, "knowledge_facts" => 1, "scenarios" => 1} =
             Packs.contributions("my_pack")

    :ok = Packs.export("my_pack", dir)

    assert %{"name" => "my_pack", "title" => "Mine"} =
             dir |> Path.join("pack.json") |> File.read!() |> Jason.decode!()

    assert {:ok, %{"signals_changed" => 0, "scenarios_added" => 0, "facts" => 1}} =
             Packs.install(dir)
  end

  test "a pack cannot take over another pack's signal", %{tmp_dir: dir} do
    {:ok, _} =
      Signals.register_signal(%{
        name: "shared",
        kind: "series",
        pack: "first",
        asserted_by: "t",
        source_spec: %{"system" => "csv", "path" => "x.csv", "fields" => %{"effective_at" => "d"}}
      })

    File.write!(Path.join(dir, "pack.json"), ~s({"name": "second"}))

    File.write!(
      Path.join(dir, "signals.json"),
      ~s([{"name": "shared", "kind": "series", "source_spec": {"system": "csv"}}])
    )

    assert {:error, {:signal_belongs_to_another_pack, "shared", "first"}} = Packs.install(dir)
    assert Packs.get_pack("second") == nil
  end

  test "a pack cannot add a predicate", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "pack.json"), ~s({"name": "bad"}))
    File.mkdir_p!(Path.join(dir, "knowledge"))

    File.write!(
      Path.join(dir, "knowledge/x.csv"),
      "predicate,subject,object\nmeans_something_new,a,b\n"
    )

    assert {:error, {:knowledge, "x.csv", {2, %{predicate: _}}}} = Packs.install(dir)
  end

  test "parse_scenarios reads titles, domains, narratives and assumptions" do
    md =
      "# Scenarios\n\n## One\n\nDomain: d\n\nFirst line.\nSecond line.\n\n- A1\n- A2\n\n## Two\n\nText.\n"

    assert [
             %{
               title: "One",
               domain: "d",
               narrative: "First line.\nSecond line.",
               assumptions: ["A1", "A2"]
             },
             %{title: "Two", domain: nil, narrative: "Text.", assumptions: []}
           ] = Packs.parse_scenarios(md)
  end

  test "available lists the shipped packs" do
    assert "regional_economy" in Packs.available()
  end
end
