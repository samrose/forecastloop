defmodule ForecastLoop.Sources.HTTPCSV do
  @moduledoc """
  Fetches a CSV document over HTTP(S). Many public statistics publishers and
  open-data portals serve data this way.

  Spec: `%{"system" => "http_csv", "url" => url, "headers" => %{...}, "fields" => ...,
  "date_format" => ...}`. See `ForecastLoop.Sources.Mapping` for `fields`.

  Extra Req options come from `config :forecast_loop, :http_csv_req_options`
  (tests use it to route requests to a stub).
  """
  @behaviour ForecastLoop.Sources

  alias ForecastLoop.Sources.CSV

  @impl true
  def describe,
    do: "CSV over HTTP(S) (spec keys: url, headers, fields, date_format, missing_values)."

  @impl true
  def fetch(spec, since) do
    with {:ok, body} <- get(spec), do: CSV.rows_from_body(body, spec, since)
  end

  @impl true
  def preview(spec) do
    with {:ok, rows} <- fetch(spec, nil), do: {:ok, Enum.take(rows, 20)}
  end

  defp get(%{"url" => url} = spec) do
    opts =
      [
        url: url,
        headers: Map.to_list(Map.get(spec, "headers", %{})),
        decode_body: false,
        retry: false,
        receive_timeout: 30_000
      ] ++ Application.get_env(:forecast_loop, :http_csv_req_options, [])

    case Req.get(opts) do
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) -> {:ok, body}
      {:ok, %Req.Response{status: status}} -> {:error, {:http_status, status}}
      {:error, exception} -> {:error, {:http, Exception.message(exception)}}
    end
  end

  defp get(_spec), do: {:error, :spec_has_no_url}
end
