defmodule ForecastLoop.Packs.ReleaseEngineering.HTTP do
  @moduledoc """
  JSON GET requests for the release_engineering pack's sources. The API token
  comes from the environment variable that the spec names. Extra Req options come
  from `config :forecast_loop, :release_engineering_req_options` (tests route
  requests to recorded fixtures with it).
  """

  @doc "GETs `url` with query `params`. Returns the decoded JSON body."
  @spec get_json(String.t(), keyword() | map(), String.t() | nil) ::
          {:ok, term()} | {:error, term()}
  def get_json(url, params, token_env) do
    with {:ok, headers} <- auth(token_env) do
      opts =
        [url: url, params: params, headers: headers, retry: false, receive_timeout: 30_000] ++
          Application.get_env(:forecast_loop, :release_engineering_req_options, [])

      case Req.get(opts) do
        {:ok, %Req.Response{status: 200, body: body}} -> {:ok, body}
        {:ok, %Req.Response{status: status}} -> {:error, {:http_status, status}}
        {:error, e} -> {:error, {:http, Exception.message(e)}}
      end
    end
  end

  defp auth(nil), do: {:ok, []}

  defp auth(env) do
    case System.get_env(env) do
      nil -> {:error, {:missing_api_token, env}}
      "" -> {:error, {:missing_api_token, env}}
      token -> {:ok, [{"authorization", "Bearer " <> token}]}
    end
  end

  @doc "Parses an ISO 8601 timestamp to a microsecond UTC DateTime, or nil."
  def time(nil), do: nil

  def time(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} ->
        %{DateTime.shift_zone!(dt, "Etc/UTC") | microsecond: {elem(dt.microsecond, 0), 6}}

      _ ->
        nil
    end
  end
end
