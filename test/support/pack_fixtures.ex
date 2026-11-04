defmodule ForecastLoop.PackFixtures do
  @moduledoc "Serves a pack's recorded HTTP fixtures through the Req.Test stub of HTTPCSV."

  @doc "Routes each FRED-style `?id=X` request to `priv/packs/<pack>/fixtures/X.csv`."
  def serve_fred_fixtures(pack) do
    dir = Path.join(:code.priv_dir(:forecast_loop), "packs/#{pack}/fixtures")

    Req.Test.stub(ForecastLoop.Sources.HTTPCSV, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      path = Path.join(dir, "#{conn.query_params["id"]}.csv")

      if File.exists?(path),
        do: Plug.Conn.send_resp(conn, 200, File.read!(path)),
        else: Plug.Conn.send_resp(conn, 404, "not recorded")
    end)
  end

  @doc """
  Routes incident.io and GitHub requests to `priv/packs/release_engineering/fixtures`.
  Page 1 of incidents points to page 2 through `pagination_meta.after`.
  """
  def serve_release_engineering_fixtures do
    dir = Path.join(:code.priv_dir(:forecast_loop), "packs/release_engineering/fixtures")

    Req.Test.stub(ForecastLoop.Packs.ReleaseEngineering.HTTP, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      case fixture_file(conn.request_path, conn.query_params) do
        :empty ->
          Req.Test.json(conn, [])

        f ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, File.read!(Path.join(dir, f)))
      end
    end)
  end

  defp fixture_file("/v2/incidents", %{"after" => _}), do: "incident_io/incidents_page2.json"
  defp fixture_file("/v2/incidents", _params), do: "incident_io/incidents_page1.json"

  defp fixture_file("/repos/" <> rest, params) do
    [owner, repo, "releases"] = String.split(rest, "/")
    if params["page"] in [nil, "1"], do: "github/#{owner}_#{repo}_releases.json", else: :empty
  end
end
