defmodule ForecastLoop.Sources.MappingTest do
  use ExUnit.Case, async: true

  alias ForecastLoop.Sources.Mapping

  @now ~U[2026-11-03 12:00:00.000000Z]

  test "maps columns, treats missing markers as nil, and stamps fetch time" do
    spec = %{
      "fields" => %{"effective_at" => "d", "value" => "v", "attributes" => %{"place" => "p"}}
    }

    recs = [
      %{"d" => "2026-09-01", "v" => "4.5", "p" => "A"},
      %{"d" => "2026-10-01", "v" => ".", "p" => "B"}
    ]

    assert {:ok, [r1, r2]} = Mapping.to_rows(recs, spec, @now)

    assert r1 == %{
             source_record_id: "2026-09-01",
             effective_at: ~U[2026-09-01 00:00:00.000000Z],
             observed_at: @now,
             value: 4.5,
             attributes: %{"place" => "A"}
           }

    assert r2.value == nil
  end

  test "supports date formats" do
    assert {:ok, ~U[2026-09-01 00:00:00.000000Z]} = Mapping.parse_time("2026-09", "ym")
    assert {:ok, ~U[2026-09-30 00:00:00.000000Z]} = Mapping.parse_time("9/30/2026", "mdy")

    assert {:ok, ~U[2026-09-30 13:00:00.000000Z]} =
             Mapping.parse_time("2026-09-30T15:00:00+02:00", "iso8601")

    assert {:error, {:bad_time, "soon"}} = Mapping.parse_time("soon", "iso8601")
  end

  test "one bad record fails the whole set" do
    spec = %{"fields" => %{"effective_at" => "d", "value" => "v"}}
    recs = [%{"d" => "2026-09-01", "v" => "1"}, %{"d" => "2026-10-01", "v" => "x"}]
    assert {:error, {:bad_record, 2, {:bad_value, "x"}}} = Mapping.to_rows(recs, spec, @now)
  end

  test "a missing declared column is a shape change" do
    spec = %{
      "fields" => %{"effective_at" => "d", "value" => "v", "attributes" => %{"k" => "kind"}}
    }

    assert :ok = Mapping.check_columns(["d", "v", "kind", "extra"], spec)

    assert {:error, {:shape_changed, %{missing_columns: ["kind"]}}} =
             Mapping.check_columns(["d", "v"], spec)
  end

  test "rows not after `since` are dropped" do
    spec = %{"fields" => %{"effective_at" => "d", "observed_at" => "o"}}

    recs = [
      %{"d" => "2026-09-01", "o" => "2026-09-05"},
      %{"d" => "2026-09-01", "o" => "2026-10-05"}
    ]

    assert {:ok, [%{observed_at: ~U[2026-10-05 00:00:00.000000Z]}]} =
             Mapping.to_rows(recs, spec, @now, ~U[2026-09-05 00:00:00.000000Z])
  end
end
