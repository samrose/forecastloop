defmodule ForecastLoop.MCP.Validate do
  @moduledoc """
  Validates tool arguments against the subset of JSON Schema that the tools use:
  `type` (string, integer, number, boolean, object, array), `required`,
  `properties`, `additionalProperties: false`, `enum`, `minimum`, `maximum`,
  `items`, and `format: "date-time"` / `"date"`.
  """

  @spec validate(term(), map()) :: :ok | {:error, [String.t()]}
  def validate(value, schema) do
    case check(value, schema, "arguments") do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  defp check(value, schema, path) do
    with [] <- type(value, schema["type"], path),
         [] <- enum(value, schema["enum"], path),
         [] <- range(value, schema, path),
         [] <- format(value, schema["format"], path) do
      children(value, schema, path)
    end
  end

  defp type(_v, nil, _p), do: []

  defp type(v, t, p) do
    ok =
      case t do
        "string" -> is_binary(v)
        "integer" -> is_integer(v)
        "number" -> is_number(v)
        "boolean" -> is_boolean(v)
        "object" -> is_map(v)
        "array" -> is_list(v)
      end

    if ok, do: [], else: ["#{p} must be of type #{t}"]
  end

  defp enum(_v, nil, _p), do: []

  defp enum(v, values, p),
    do: if(v in values, do: [], else: ["#{p} must be one of #{Enum.join(values, ", ")}"])

  defp range(v, s, p) when is_number(v) do
    lo = s["minimum"]
    hi = s["maximum"]

    cond do
      lo && v < lo -> ["#{p} must be at least #{lo}"]
      hi && v > hi -> ["#{p} must be at most #{hi}"]
      true -> []
    end
  end

  defp range(_v, _s, _p), do: []

  defp format(v, "date-time", p) when is_binary(v) do
    case DateTime.from_iso8601(v) do
      {:ok, _, _} -> []
      _ -> ["#{p} must be an ISO 8601 date-time with offset, for example 2027-01-01T00:00:00Z"]
    end
  end

  defp format(v, "date", p) when is_binary(v) do
    case Date.from_iso8601(v) do
      {:ok, _} -> []
      _ -> ["#{p} must be an ISO 8601 date, for example 2027-01-01"]
    end
  end

  defp format(_v, _f, _p), do: []

  defp children(v, %{"type" => "object"} = s, p) when is_map(v) do
    props = Map.get(s, "properties", %{})

    missing =
      for r <- Map.get(s, "required", []), not Map.has_key?(v, r), do: "#{p}.#{r} is required"

    extra =
      if s["additionalProperties"] == false,
        do:
          for(k <- Map.keys(v), not Map.has_key?(props, k), do: "#{p}.#{k} is not a known field"),
        else: []

    nested =
      for {k, sub} <- props, Map.has_key?(v, k), err <- check(v[k], sub, "#{p}.#{k}"), do: err

    missing ++ extra ++ nested
  end

  defp children(v, %{"type" => "array", "items" => items}, p) when is_list(v) do
    v |> Enum.with_index() |> Enum.flat_map(fn {x, i} -> check(x, items, "#{p}[#{i}]") end)
  end

  defp children(_v, _s, _p), do: []
end
