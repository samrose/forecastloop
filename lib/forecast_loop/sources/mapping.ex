defmodule ForecastLoop.Sources.Mapping do
  @moduledoc """
  Maps tabular records (maps of column name to value) to source rows, using the
  `fields` part of a spec. CSV, HTTP CSV and Postgres sources share it.

      "fields" => %{
        "effective_at" => "DATE",            # required: column with the event or period time
        "source_record_id" => "DATE",        # optional: defaults to the effective_at column
        "value" => "UNRATE",                 # optional: numeric column
        "observed_at" => "realtime_start",   # optional: vintage column; default is fetch time
        "attributes" => %{"place" => "area"} # optional: attribute name => column
      },
      "date_format" => "iso8601",            # iso8601 | ymd | mdy | ym, or a map
                                             # %{"effective_at" => "ym", "observed_at" => "ymd"}
      "missing_values" => ["", "."]          # strings that mean "no value"
  """

  alias ForecastLoop.Sources

  @doc "Columns that the spec's `fields` need."
  @spec declared_columns(Sources.spec()) :: [String.t()]
  def declared_columns(spec) do
    f = Map.get(spec, "fields", %{})

    ([f["effective_at"], f["source_record_id"], f["value"], f["observed_at"]] ++
       Map.values(Map.get(f, "attributes", %{})))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  @doc "Checks that every declared column is present. Returns a shape error if not."
  @spec check_columns([String.t()], Sources.spec()) :: :ok | {:error, term()}
  def check_columns(columns, spec) do
    case declared_columns(spec) -- columns do
      [] -> :ok
      missing -> {:error, {:shape_changed, %{missing_columns: missing, columns: columns}}}
    end
  end

  @doc """
  Maps records to rows. Fails on the first bad record, so a source never returns a
  partial set. Rows with an `observed_at` not after `since` are dropped.
  """
  @spec to_rows([map()], Sources.spec(), DateTime.t(), DateTime.t() | nil) ::
          {:ok, [Sources.row()]} | {:error, term()}
  def to_rows(records, spec, fetched_at, since \\ nil) do
    f = Map.get(spec, "fields", %{})

    with :ok <- require_effective_at(f),
         {:ok, rows} <- map_all(records, f, spec, fetched_at) do
      {:ok, after_since(rows, since)}
    end
  end

  defp require_effective_at(%{"effective_at" => col}) when is_binary(col), do: :ok
  defp require_effective_at(_fields), do: {:error, :fields_effective_at_missing}

  defp map_all(records, f, spec, fetched_at) do
    records
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {rec, i}, {:ok, acc} ->
      case to_row(rec, f, spec, fetched_at) do
        {:ok, row} -> {:cont, {:ok, [row | acc]}}
        {:error, reason} -> {:halt, {:error, {:bad_record, i, reason}}}
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      error -> error
    end
  end

  defp after_since(rows, nil), do: rows

  defp after_since(rows, since),
    do: Enum.filter(rows, &(DateTime.compare(&1.observed_at, since) == :gt))

  defp to_row(rec, f, spec, fetched_at) do
    fmt = &date_format(spec, &1)
    missing = Map.get(spec, "missing_values", ["", "."])

    with {:ok, eff} <- parse_time(rec[f["effective_at"]], fmt.("effective_at")),
         {:ok, obs} <- observed_at(rec, f, fmt, fetched_at),
         {:ok, value} <- parse_value(f["value"] && rec[f["value"]], missing) do
      id_col = f["source_record_id"] || f["effective_at"]

      {:ok,
       %{
         source_record_id: to_string(rec[id_col]),
         effective_at: eff,
         observed_at: obs,
         value: value,
         attributes:
           Map.new(Map.get(f, "attributes", %{}), fn {name, col} ->
             {name, json_safe(rec[col])}
           end)
       }}
    end
  end

  defp observed_at(rec, f, fmt, fetched_at) do
    case f["observed_at"] do
      nil -> {:ok, fetched_at}
      col -> parse_time(rec[col], fmt.("observed_at"))
    end
  end

  defp date_format(spec, field) do
    case Map.get(spec, "date_format", "iso8601") do
      fmt when is_binary(fmt) -> fmt
      fmts when is_map(fmts) -> Map.get(fmts, field, "iso8601")
    end
  end

  @doc "Parses a time value in one of the supported formats to a UTC DateTime (microsecond precision)."
  @spec parse_time(term(), String.t()) :: {:ok, DateTime.t()} | {:error, term()}
  def parse_time(%DateTime{} = dt, _fmt), do: {:ok, usec(dt)}

  def parse_time(%NaiveDateTime{} = n, _fmt),
    do: {:ok, n |> DateTime.from_naive!("Etc/UTC") |> usec()}

  def parse_time(%Date{} = d, _fmt), do: {:ok, midnight(d)}

  def parse_time(s, fmt) when is_binary(s) do
    s = String.trim(s)

    result =
      case fmt do
        "iso8601" -> iso(s)
        "ymd" -> date(s)
        "ym" -> date(s <> "-01")
        "mdy" -> mdy(s)
        other -> {:error, {:unknown_date_format, other}}
      end

    case result do
      {:ok, dt} -> {:ok, dt}
      {:error, {:unknown_date_format, _}} = e -> e
      {:error, _} -> {:error, {:bad_time, s}}
    end
  end

  def parse_time(other, _fmt), do: {:error, {:bad_time, other}}

  defp iso(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} -> {:ok, usec(dt)}
      {:error, _} -> date(s)
    end
  end

  defp date(s) do
    with {:ok, d} <- Date.from_iso8601(s), do: {:ok, midnight(d)}
  end

  defp mdy(s) do
    with [m, d, y] <- String.split(s, "/"),
         {m, ""} <- Integer.parse(m),
         {d, ""} <- Integer.parse(d),
         {y, ""} <- Integer.parse(y),
         {:ok, date} <- Date.new(y, m, d) do
      {:ok, midnight(date)}
    else
      _ -> {:error, :bad_mdy}
    end
  end

  defp midnight(d), do: d |> DateTime.new!(~T[00:00:00.000000], "Etc/UTC")

  defp usec(dt),
    do:
      dt
      |> DateTime.shift_zone!("Etc/UTC")
      |> Map.update!(:microsecond, fn {us, _} -> {us, 6} end)

  defp parse_value(nil, _missing), do: {:ok, nil}
  defp parse_value(v, _missing) when is_integer(v), do: {:ok, v * 1.0}
  defp parse_value(v, _missing) when is_float(v), do: {:ok, v}
  defp parse_value(%Decimal{} = d, _missing), do: {:ok, Decimal.to_float(d)}

  defp parse_value(v, missing) when is_binary(v) do
    t = String.trim(v)

    if t in missing do
      {:ok, nil}
    else
      case Float.parse(t) do
        {f, ""} -> {:ok, f}
        _ -> {:error, {:bad_value, v}}
      end
    end
  end

  defp parse_value(v, _missing), do: {:error, {:bad_value, v}}

  defp json_safe(%Decimal{} = d), do: Decimal.to_float(d)
  defp json_safe(%DateTime{} = d), do: DateTime.to_iso8601(d)
  defp json_safe(%NaiveDateTime{} = d), do: NaiveDateTime.to_iso8601(d)
  defp json_safe(%Date{} = d), do: Date.to_iso8601(d)
  defp json_safe(v), do: v
end
