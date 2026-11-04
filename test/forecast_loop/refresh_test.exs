defmodule ForecastLoop.RefreshTest do
  use ForecastLoop.DataCase, async: true

  alias ForecastLoop.{Batch, Observations, Refresh, Signals}

  @moduletag :tmp_dir

  defp csv_signal(dir, body) do
    path = Path.join(dir, "series.csv")
    File.write!(path, body)

    {:ok, s} =
      Signals.register_signal(%{
        name: "series_a",
        domain: "test_domain",
        kind: "series",
        source_spec: %{
          "system" => "csv",
          "path" => path,
          "fields" => %{"effective_at" => "DATE", "value" => "VALUE"}
        },
        asserted_by: "test"
      })

    {s, path}
  end

  defp values(s, t), do: s.id |> List.wrap() |> Observations.as_of(t) |> Enum.map(& &1.value)

  defp count(s),
    do:
      Repo.aggregate(
        from(o in ForecastLoop.Signals.Observation, where: o.signal_id == ^s.id),
        :count
      )

  test "a revised value becomes a new vintage; as-of before it sees the old value", %{
    tmp_dir: dir
  } do
    {s, path} = csv_signal(dir, "DATE,VALUE\n2026-08-01,4.2\n2026-09-01,4.3\n")
    assert {:ok, 2} = Refresh.refresh_signal(s)
    before_revision = DateTime.utc_now()

    File.write!(path, "DATE,VALUE\n2026-08-01,4.4\n2026-09-01,4.3\n2026-10-01,4.6\n")
    assert {:ok, 2} = Refresh.refresh_signal(Signals.get!(s.id))

    assert values(s, before_revision) == [4.2, 4.3]
    assert values(s, DateTime.utc_now()) == [4.4, 4.3, 4.6]
    assert count(s) == 4
  end

  test "refreshing unchanged data appends nothing and does not touch the signal", %{tmp_dir: dir} do
    {s, _} = csv_signal(dir, "DATE,VALUE\n2026-08-01,4.2\n")
    assert {:ok, 1} = Refresh.refresh_signal(s)
    s1 = Signals.get!(s.id)
    assert {:ok, 0} = Refresh.refresh_signal(s1)
    assert Signals.get!(s.id).updated_at == s1.updated_at
    assert s1.coverage_start == ~U[2026-08-01 00:00:00.000000Z]
  end

  test "a value that returns to an earlier value is still a new vintage", %{tmp_dir: dir} do
    {s, path} = csv_signal(dir, "DATE,VALUE\n2026-08-01,4.2\n")
    {:ok, 1} = Refresh.refresh_signal(s)
    File.write!(path, "DATE,VALUE\n2026-08-01,4.4\n")
    {:ok, 1} = Refresh.refresh_signal(s)
    File.write!(path, "DATE,VALUE\n2026-08-01,4.2\n")
    {:ok, 1} = Refresh.refresh_signal(s)
    assert count(s) == 3
  end

  test "one bad row ingests nothing and opens refresh_failed; a good refresh closes it", %{
    tmp_dir: dir
  } do
    {s, path} = csv_signal(dir, File.read!("test/fixtures/sources/bad_row.csv"))
    assert {:error, :refresh_failed, {:bad_record, 2, _}} = Refresh.refresh_signal(s, run_id: nil)
    assert count(s) == 0
    assert [%{kind: "refresh_failed", subject_id: sid}] = Batch.list_work_items()
    assert sid == to_string(s.id)

    # A second failure does not duplicate the open item.
    {:error, :refresh_failed, _} = Refresh.refresh_signal(s)
    assert length(Batch.list_work_items()) == 1

    File.write!(path, "DATE,VALUE\n2026-06-01,4.0\n")
    assert {:ok, 1} = Refresh.refresh_signal(s)
    assert Batch.list_work_items() == []
    assert [%{kind: "refresh_failed"}] = Batch.list_work_items(status: "done")
  end

  test "a shape change opens definition_change and ingests nothing", %{tmp_dir: dir} do
    {s, path} = csv_signal(dir, "DATE,VALUE\n2026-08-01,4.2\n")
    {:ok, 1} = Refresh.refresh_signal(s)
    File.write!(path, "DATE,RATE\n2026-09-01,4.3\n")
    assert {:error, :definition_change, %{missing_columns: ["VALUE"]}} = Refresh.refresh_signal(s)
    assert count(s) == 1

    assert [%{kind: "definition_change", payload: %{"signal" => "series_a"}}] =
             Batch.list_work_items()
  end

  test "source-supplied vintages are kept, and replaying them adds nothing" do
    {:ok, s} =
      Signals.register_signal(%{
        name: "vintaged",
        kind: "series",
        source_spec: %{
          "system" => "csv",
          "path" => "test/fixtures/sources/monthly_vintages.csv",
          "date_format" => %{"effective_at" => "ym", "observed_at" => "ymd"},
          "fields" => %{
            "effective_at" => "period",
            "value" => "value",
            "observed_at" => "published"
          }
        },
        asserted_by: "test"
      })

    assert {:ok, 3} = Refresh.refresh_signal(s)
    assert {:ok, 0} = Refresh.refresh_signal(s)
    assert values(s, ts("2026-09-30T00:00:00Z")) == [4.2]
    assert values(s, ts("2026-10-06T00:00:00Z")) == [4.4, 4.5]
  end

  test "refresh_all skips derived signals and reports stats", %{tmp_dir: dir} do
    {_s, _} = csv_signal(dir, "DATE,VALUE\n2026-08-01,4.2\n")

    {:ok, _} =
      Signals.register_signal(%{
        name: "series_a_change",
        kind: "derived",
        source_spec: %{
          "system" => "derived",
          "operation" => "change_over_periods",
          "signal" => "series_a",
          "lag" => 1
        },
        asserted_by: "test"
      })

    assert %{"signals" => 1, "appended" => 1, "failed" => 0, "definition_changes" => 0} =
             Refresh.refresh_all()
  end

  test "register_signal rejects an unknown system" do
    assert {:error, cs} =
             Signals.register_signal(%{
               name: "x",
               kind: "series",
               source_spec: %{"system" => "nope"},
               asserted_by: "t"
             })

    assert cs.errors[:source_spec]
  end

  test "with a publication lag, backfill gets assumed vintages and a later revision gets fetch time",
       %{tmp_dir: dir} do
    path = Path.join(dir, "lagged.csv")
    File.write!(path, "DATE,VALUE\n2025-01-01,4.0\n2025-02-01,4.1\n")

    {:ok, s} =
      Signals.register_signal(%{
        name: "lagged",
        kind: "series",
        asserted_by: "t",
        source_spec: %{
          "system" => "csv",
          "path" => path,
          "publication_lag" => "P1M20D",
          "fields" => %{"effective_at" => "DATE", "value" => "VALUE"}
        }
      })

    assert {:ok, 2} = Refresh.refresh_signal(s)
    assert values(s, ts("2025-02-25T00:00:00Z")) == [4.0]
    assert values(s, ts("2025-03-25T00:00:00Z")) == [4.0, 4.1]
    assert {:ok, 0} = Refresh.refresh_signal(s)

    File.write!(path, "DATE,VALUE\n2025-01-01,4.0\n2025-02-01,4.3\n")
    before = DateTime.utc_now()
    assert {:ok, 1} = Refresh.refresh_signal(s)
    assert values(s, ts("2025-03-25T00:00:00Z")) == [4.0, 4.1]
    assert values(s, DateTime.add(DateTime.utc_now(), 1)) == [4.0, 4.3]
    assert values(s, before) == [4.0, 4.1]
  end
end
