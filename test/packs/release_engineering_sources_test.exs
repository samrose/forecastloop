defmodule ForecastLoop.Packs.ReleaseEngineering.SourcesTest do
  use ExUnit.Case, async: false

  import ForecastLoop.PackFixtures

  alias ForecastLoop.Packs.ReleaseEngineering.Sources.{GitHubReleases, IncidentIO}
  alias ForecastLoop.Sources

  @incident_spec %{
    "system" => "incident_io",
    "api_key_env" => "INCIDENT_IO_API_KEY",
    "custom_fields" => %{"service" => "Affected services", "cause" => "Cause"},
    "timestamps" => %{"resolved_at" => "Resolved at"}
  }

  setup do
    System.put_env("INCIDENT_IO_API_KEY", "test-key")
    serve_release_engineering_fixtures()
    on_exit(fn -> System.delete_env("INCIDENT_IO_API_KEY") end)
  end

  test "the pack's sources are found without config" do
    assert {:ok, IncidentIO} = Sources.module_for(%{"system" => "incident_io"})
    assert {:ok, GitHubReleases} = Sources.module_for(%{"system" => "github_releases"})
  end

  test "incident.io: follows pages, maps fields, skips test incidents" do
    assert {:ok, rows} = IncidentIO.fetch(@incident_spec, nil)

    assert Enum.map(rows, & &1.source_record_id) ==
             ~w(01HQ0001 01HQ0002 01HQ0003 01HQ0004 01HQ0005 01HQ0006)

    [first | _] = rows
    assert first.effective_at == ~U[2026-01-10 20:00:00.000000Z]
    assert first.observed_at == ~U[2026-01-11 02:00:00.000000Z]

    assert first.attributes == %{
             "severity" => "P0",
             "status" => "closed",
             "mode" => "standard",
             "service" => ["auth-api"],
             "resolved_at" => "2026-01-11T01:30:00Z"
           }

    assert Enum.find(rows, &(&1.source_record_id == "01HQ0003")).attributes["cause"] == ["deploy"]
  end

  test "incident.io: sends the API key and the since filter" do
    Req.Test.stub(ForecastLoop.Packs.ReleaseEngineering.HTTP, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      send(self(), {:request, Plug.Conn.get_req_header(conn, "authorization"), conn.query_params})
      Req.Test.json(conn, %{"incidents" => [], "pagination_meta" => %{}})
    end)

    assert {:ok, []} = IncidentIO.fetch(@incident_spec, ~U[2026-02-01 00:00:00Z])
    # Plug decodes the bracketed parameter name updated_at[gte] into a nested map.
    assert_received {:request, ["Bearer test-key"],
                     %{"updated_at" => %{"gte" => "2026-02-01T00:00:00Z"}, "page_size" => "250"}}
  end

  test "incident.io: a missing API key is an error" do
    System.delete_env("INCIDENT_IO_API_KEY")

    assert {:error, {:missing_api_token, "INCIDENT_IO_API_KEY"}} =
             IncidentIO.fetch(@incident_spec, nil)
  end

  test "incident.io: a body without incidents is a shape change" do
    Req.Test.stub(ForecastLoop.Packs.ReleaseEngineering.HTTP, &Req.Test.json(&1, %{"data" => []}))
    assert {:error, {:shape_changed, _}} = IncidentIO.fetch(@incident_spec, nil)
  end

  test "GitHub releases: all repositories, drafts skipped, known when published" do
    spec = %{
      "system" => "github_releases",
      "kind" => "releases",
      "repos" => ["acme/auth-service", "acme/web", "acme/payments"]
    }

    assert {:ok, rows} = GitHubReleases.fetch(spec, nil)
    assert length(rows) == 8
    refute Enum.any?(rows, &(&1.attributes["tag"] == "v1.8.0-draft"))

    r = Enum.find(rows, &(&1.source_record_id == "acme/auth-service#1001"))
    assert r.effective_at == ~U[2026-01-10 10:00:00.000000Z] and r.observed_at == r.effective_at

    assert r.attributes == %{
             "repo" => "acme/auth-service",
             "tag" => "v1.4.0",
             "prerelease" => false
           }
  end
end
