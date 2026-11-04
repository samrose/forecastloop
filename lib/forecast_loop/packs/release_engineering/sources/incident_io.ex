defmodule ForecastLoop.Packs.ReleaseEngineering.Sources.IncidentIO do
  @moduledoc """
  Incidents from the incident.io REST API (`GET /v2/incidents`), as events.

  Spec:

      %{"system" => "incident_io",
        "base_url" => "https://api.incident.io",      # optional
        "api_key_env" => "INCIDENT_IO_API_KEY",       # environment variable with the API key
        "page_size" => 250,                           # optional
        "custom_fields" => %{"service" => "Affected services", "cause" => "Cause"},
        "timestamps" => %{"resolved_at" => "Resolved at"}}

  Each incident becomes one row: `source_record_id` = incident id, `effective_at` =
  `created_at`, `observed_at` = `updated_at` (so an update is a new vintage).
  Attributes: `severity` (severity name), `status` (status category), `mode`, and one
  attribute for each entry of `custom_fields` (a list of option, text or catalog
  values) and `timestamps`. Incidents in test or tutorial mode are skipped.
  With `since`, the request asks only for incidents updated at or after it.
  """
  @behaviour ForecastLoop.Sources

  alias ForecastLoop.Packs.ReleaseEngineering.HTTP

  @max_pages 200

  @impl true
  def system, do: "incident_io"

  @impl true
  def describe,
    do: "incident.io incidents (spec keys: api_key_env, custom_fields, timestamps, base_url)."

  @impl true
  def fetch(spec, since), do: pages(spec, since, nil, [], 0)

  @impl true
  def preview(spec) do
    with {:ok, rows} <- pages(spec, nil, nil, [], @max_pages - 1), do: {:ok, Enum.take(rows, 20)}
  end

  defp pages(_spec, _since, _after, _acc, n) when n >= @max_pages, do: {:error, :too_many_pages}

  defp pages(spec, since, cursor, acc, n) do
    params =
      [page_size: Map.get(spec, "page_size", 250)] ++
        if(cursor, do: [after: cursor], else: []) ++
        if(since, do: ["updated_at[gte]": DateTime.to_iso8601(since)], else: [])

    url = Map.get(spec, "base_url", "https://api.incident.io") <> "/v2/incidents"

    with {:ok, %{"incidents" => incidents} = body} <-
           HTTP.get_json(url, params, Map.get(spec, "api_key_env")),
         {:ok, rows} <- map_incidents(incidents, spec) do
      acc = acc ++ rows

      case get_in(body, ["pagination_meta", "after"]) do
        next when is_binary(next) and next != "" and incidents != [] ->
          pages(spec, since, next, acc, n + 1)

        _ ->
          {:ok, acc}
      end
    else
      {:ok, _other} -> {:error, {:shape_changed, %{missing_columns: ["incidents"]}}}
      error -> error
    end
  end

  defp map_incidents(incidents, spec) do
    incidents
    |> Enum.reject(&(&1["mode"] in ["test", "tutorial"]))
    |> Enum.reduce_while({:ok, []}, fn inc, {:ok, acc} ->
      case to_row(inc, spec) do
        {:ok, row} -> {:cont, {:ok, [row | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      error -> error
    end
  end

  defp to_row(%{"id" => id} = inc, spec) do
    created = HTTP.time(inc["created_at"])
    updated = HTTP.time(inc["updated_at"]) || created

    if created do
      attrs =
        %{
          "severity" => get_in(inc, ["severity", "name"]),
          "status" => get_in(inc, ["incident_status", "category"]),
          "mode" => inc["mode"]
        }
        |> Map.merge(custom_fields(inc, Map.get(spec, "custom_fields", %{})))
        |> Map.merge(timestamps(inc, Map.get(spec, "timestamps", %{})))
        |> Map.reject(fn {_k, v} -> is_nil(v) end)

      {:ok,
       %{
         source_record_id: id,
         effective_at: created,
         observed_at: updated,
         value: nil,
         attributes: attrs
       }}
    else
      {:error, {:bad_record, id, :no_created_at}}
    end
  end

  defp to_row(_inc, _spec), do: {:error, {:shape_changed, %{missing_columns: ["id"]}}}

  defp custom_fields(inc, wanted) do
    entries =
      Map.new(
        inc["custom_field_entries"] || [],
        &{get_in(&1, ["custom_field", "name"]), &1["values"] || []}
      )

    Map.new(wanted, fn {attr, field_name} ->
      values =
        entries |> Map.get(field_name, []) |> Enum.map(&field_value/1) |> Enum.reject(&is_nil/1)

      {attr, if(values == [], do: nil, else: values)}
    end)
  end

  defp field_value(%{"value_option" => %{"value" => v}}), do: v
  defp field_value(%{"value_catalog_entry" => %{"name" => v}}), do: v
  defp field_value(%{"value_text" => v}) when is_binary(v), do: v
  defp field_value(%{"value_numeric" => v}), do: v
  defp field_value(_), do: nil

  defp timestamps(inc, wanted) do
    values =
      Map.new(
        inc["incident_timestamp_values"] || [],
        &{get_in(&1, ["incident_timestamp", "name"]), get_in(&1, ["value", "value"])}
      )

    Map.new(wanted, fn {attr, name} -> {attr, values[name]} end)
  end
end
