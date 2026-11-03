defmodule ForecastLoop.Sources.CSV do
  @moduledoc """
  Reads a CSV file with a header row. Use it for backfills and recorded fixtures.

  Spec: `%{"system" => "csv", "path" => path, "fields" => ..., "date_format" => ...}`.
  A `path` that starts with `priv:` is relative to the application's `priv/`
  directory; any other relative path is relative to the working directory.
  See `ForecastLoop.Sources.Mapping` for `fields`.
  """
  @behaviour ForecastLoop.Sources

  alias ForecastLoop.Sources.Mapping

  @preview_rows 20

  @impl true
  def describe,
    do: "CSV file with a header row (spec keys: path, fields, date_format, missing_values)."

  @impl true
  def fetch(spec, since) do
    with {:ok, body} <- read(spec), do: rows_from_body(body, spec, since)
  end

  @impl true
  def preview(spec) do
    with {:ok, rows} <- fetch(spec, nil), do: {:ok, Enum.take(rows, @preview_rows)}
  end

  @doc "Parses CSV text and maps it to rows. HTTPCSV uses it too."
  @spec rows_from_body(String.t(), map(), DateTime.t() | nil) ::
          {:ok, [ForecastLoop.Sources.row()]} | {:error, term()}
  def rows_from_body(body, spec, since) do
    with {:ok, columns, records} <- parse(body),
         :ok <- Mapping.check_columns(columns, spec) do
      Mapping.to_rows(records, spec, fetched_at(), since)
    end
  end

  @doc "Parses CSV text into its header and a list of records (column => value)."
  @spec parse(String.t()) :: {:ok, [String.t()], [map()]} | {:error, term()}
  def parse(body) do
    body = String.replace_prefix(body, "﻿", "")

    case NimbleCSV.RFC4180.parse_string(body, skip_headers: false) do
      [] ->
        {:error, :empty_csv}

      [header | rows] ->
        header = Enum.map(header, &String.trim/1)
        width = length(header)

        case Enum.find_index(rows, &(length(&1) != width)) do
          nil -> {:ok, header, Enum.map(rows, &(header |> Enum.zip(&1) |> Map.new()))}
          i -> {:error, {:ragged_row, i + 2}}
        end
    end
  rescue
    e in NimbleCSV.ParseError -> {:error, {:csv_parse, Exception.message(e)}}
  end

  @doc false
  def fetched_at, do: DateTime.utc_now()

  defp read(%{"path" => "priv:" <> rel}),
    do: read(%{"path" => Path.join(:code.priv_dir(:forecast_loop), rel)})

  defp read(%{"path" => path}) do
    case File.read(path) do
      {:ok, body} -> {:ok, body}
      {:error, reason} -> {:error, {:file, path, reason}}
    end
  end

  defp read(_spec), do: {:error, :spec_has_no_path}
end
