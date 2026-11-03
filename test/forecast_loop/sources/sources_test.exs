defmodule ForecastLoop.Sources.SourcesTest do
  use ForecastLoop.DataCase, async: true

  alias ForecastLoop.Sources
  alias ForecastLoop.Sources.{CSV, HTTPCSV, Postgres}

  @fields %{"effective_at" => "DATE", "value" => "VALUE"}

  test "registry lists the core systems with descriptions" do
    systems = Sources.list() |> Enum.map(& &1.system)
    assert ~w(csv derived http_csv postgres) -- systems == []
    assert {:error, {:unknown_system, "nope"}} = Sources.module_for(%{"system" => "nope"})
  end

  describe "CSV" do
    test "reads a file" do
      spec = %{
        "system" => "csv",
        "path" => "test/fixtures/sources/monthly_v1.csv",
        "fields" => @fields
      }

      assert {:ok, rows} = CSV.fetch(spec, nil)
      assert Enum.map(rows, & &1.value) == [4.0, 4.1, nil, 4.3]
    end

    test "a missing file is an error" do
      assert {:error, {:file, _, :enoent}} =
               CSV.fetch(%{"path" => "nope.csv", "fields" => @fields}, nil)
    end

    test "a renamed column is a shape change" do
      spec = %{
        "path" => "test/fixtures/sources/monthly_v1.csv",
        "fields" => %{"effective_at" => "DATE", "value" => "UNRATE"}
      }

      assert {:error, {:shape_changed, %{missing_columns: ["UNRATE"]}}} = CSV.fetch(spec, nil)
    end

    test "uses a vintage column for observed_at, with a date format per field" do
      spec = %{
        "path" => "test/fixtures/sources/monthly_vintages.csv",
        "date_format" => %{"effective_at" => "ym", "observed_at" => "ymd"},
        "fields" => %{
          "effective_at" => "period",
          "value" => "value",
          "observed_at" => "published"
        }
      }

      assert {:ok, rows} = CSV.fetch(spec, nil)

      assert Enum.map(rows, &{&1.source_record_id, &1.value, Date.to_iso8601(&1.observed_at)}) ==
               [
                 {"2026-08", 4.2, "2026-09-05"},
                 {"2026-08", 4.4, "2026-10-05"},
                 {"2026-09", 4.5, "2026-10-05"}
               ]

      # One date format for every field fails on the first record.
      assert {:error, {:bad_record, 1, {:bad_time, "2026-08"}}} =
               CSV.fetch(%{spec | "date_format" => "iso8601"}, nil)
    end
  end

  describe "HTTPCSV" do
    @spec_http %{
      "system" => "http_csv",
      "url" => "https://data.example/series.csv",
      "fields" => @fields
    }

    test "fetches and parses CSV" do
      Req.Test.stub(HTTPCSV, &Req.Test.text(&1, "DATE,VALUE\n2026-09-01,4.5\n"))
      assert {:ok, [%{value: 4.5}]} = HTTPCSV.fetch(@spec_http, nil)
    end

    test "a non-200 status is an error" do
      Req.Test.stub(HTTPCSV, &Plug.Conn.send_resp(&1, 503, "down"))
      assert {:error, {:http_status, 503}} = HTTPCSV.fetch(@spec_http, nil)
    end

    test "a transport error is an error" do
      Req.Test.stub(HTTPCSV, &Req.Test.transport_error(&1, :econnrefused))
      assert {:error, {:http, _}} = HTTPCSV.fetch(@spec_http, nil)
    end
  end

  describe "Postgres" do
    test "runs a query against the repo connection" do
      spec = %{
        "system" => "postgres",
        "connection" => "repo",
        "query" => "SELECT * FROM (VALUES (date '2026-09-01', 4.5::numeric, 'a')) t(d, v, k)",
        "fields" => %{"effective_at" => "d", "value" => "v", "attributes" => %{"k" => "k"}}
      }

      assert {:ok,
              [
                %{
                  value: 4.5,
                  attributes: %{"k" => "a"},
                  effective_at: ~U[2026-09-01 00:00:00.000000Z]
                }
              ]} =
               Postgres.fetch(spec, nil)
    end

    test "binds $1 to since" do
      spec = %{"query" => "SELECT $1::timestamptz AS d", "fields" => %{"effective_at" => "d"}}
      since = ~U[2026-10-01 00:00:00.000000Z]
      assert {:ok, [%{effective_at: ^since}]} = Postgres.fetch(spec, since)
    end

    test "writes are refused and leave no trace" do
      spec = %{
        "query" =>
          "INSERT INTO config (key, value, asserted_by, inserted_at, updated_at) VALUES ('x', '{}', 't', now(), now()) RETURNING key AS d",
        "fields" => %{"effective_at" => "d"}
      }

      assert {:error, {:query, msg}} = Postgres.fetch(spec, nil)
      assert msg =~ "read-only"
      # The enclosing (sandbox) transaction is still writable.
      assert {:ok, _} =
               Repo.query(
                 "INSERT INTO config (key, value, asserted_by, inserted_at, updated_at) VALUES ('y', '{}', 't', now(), now())"
               )
    end
  end
end
