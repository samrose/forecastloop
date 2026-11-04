defmodule ForecastLoop.Packs.ReleaseEngineering.Sources.GitHubReleases do
  @moduledoc """
  Releases or deployments of one or more GitHub repositories, as events.

  Spec:

      %{"system" => "github_releases",
        "repos" => ["acme/auth-service", "acme/web"],
        "kind" => "releases" | "deployments",
        "environment" => "production",     # deployments only, optional
        "token_env" => "GITHUB_TOKEN",     # optional for public repositories
        "base_url" => "https://api.github.com"}

  Releases: `GET /repos/{repo}/releases` (drafts are skipped). `effective_at` and
  `observed_at` are both `published_at`: a release is public from that moment, and
  GitHub gives no update time for a release. An edit to a published release is not
  stored as a new vintage. Deployments:
  `GET /repos/{repo}/deployments`; `effective_at` = `created_at`; `observed_at` =
  `updated_at`. `source_record_id` = "<repo>#<id>". Attributes: `repo`, `tag` or
  `ref`, `environment`, `prerelease`.
  """
  @behaviour ForecastLoop.Sources

  alias ForecastLoop.Packs.ReleaseEngineering.HTTP

  @per_page 100
  @max_pages 50

  @impl true
  def system, do: "github_releases"

  @impl true
  def describe,
    do:
      "GitHub releases or deployments (spec keys: repos, kind, environment, token_env, base_url)."

  @impl true
  def fetch(spec, since) do
    now = DateTime.utc_now()

    spec
    |> Map.get("repos", [])
    |> Enum.reduce_while({:ok, []}, fn repo, {:ok, acc} ->
      case repo_rows(spec, repo, now) do
        {:ok, rows} -> {:cont, {:ok, acc ++ rows}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, rows} ->
        {:ok,
         Enum.filter(rows, &(is_nil(since) or DateTime.compare(&1.observed_at, since) == :gt))}

      error ->
        error
    end
  end

  @impl true
  def preview(spec) do
    with {:ok, rows} <- fetch(spec, nil), do: {:ok, Enum.take(rows, 20)}
  end

  defp repo_rows(spec, repo, now), do: page(spec, repo, now, 1, [])

  defp page(_spec, _repo, _now, n, _acc) when n > @max_pages, do: {:error, :too_many_pages}

  defp page(spec, repo, now, n, acc) do
    kind = Map.get(spec, "kind", "releases")
    url = Map.get(spec, "base_url", "https://api.github.com") <> "/repos/#{repo}/#{kind}"

    params =
      [per_page: @per_page, page: n] ++
        if(kind == "deployments" and spec["environment"],
          do: [environment: spec["environment"]],
          else: []
        )

    case HTTP.get_json(url, params, spec["token_env"]) do
      {:ok, items} when is_list(items) ->
        rows = items |> Enum.map(&to_row(kind, repo, &1, now)) |> Enum.reject(&is_nil/1)

        if length(items) < @per_page,
          do: {:ok, acc ++ rows},
          else: page(spec, repo, now, n + 1, acc ++ rows)

      {:ok, _other} ->
        {:error, {:shape_changed, %{expected: "a JSON array", repo: repo}}}

      error ->
        error
    end
  end

  defp to_row("releases", _repo, %{"draft" => true}, _now), do: nil

  defp to_row("releases", repo, r, now) do
    with %DateTime{} = at <- HTTP.time(r["published_at"] || r["created_at"]) do
      %{
        source_record_id: "#{repo}##{r["id"]}",
        effective_at: at,
        observed_at: Enum.min([at, now], DateTime),
        value: nil,
        attributes: %{
          "repo" => repo,
          "tag" => r["tag_name"],
          "prerelease" => r["prerelease"] == true
        }
      }
    end
  end

  defp to_row("deployments", repo, d, _now) do
    with %DateTime{} = at <- HTTP.time(d["created_at"]) do
      %{
        source_record_id: "#{repo}##{d["id"]}",
        effective_at: at,
        observed_at: HTTP.time(d["updated_at"]) || at,
        value: nil,
        attributes: %{"repo" => repo, "ref" => d["ref"], "environment" => d["environment"]}
      }
    end
  end
end
