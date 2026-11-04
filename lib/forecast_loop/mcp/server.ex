defmodule ForecastLoop.MCP.Server do
  @moduledoc """
  A Model Context Protocol (MCP) server on the stdio transport: one JSON-RPC 2.0
  message per line on stdin, one response per line on stdout. It answers
  `initialize`, `ping`, `tools/list` and `tools/call` (tools in
  `ForecastLoop.MCP.Tools`). Logs go to stderr, so stdout carries only protocol
  messages.

  No LLM call happens inside the nightly batch. LLM-assisted work happens only here,
  when a person drives a session.
  """
  alias ForecastLoop.MCP.Tools

  @protocol_version "2025-06-18"

  @instructions """
  ForecastLoop is a forecast ledger. Use list_gaps and list_work_items to see what the
  system needs. A question needs all four Forecast Integrity Protocol fields
  (event_definition, resolution_condition, deadline, domain) and a reviewer who is not
  its author before it goes live. Forecasts are append-only probabilities. Use query to
  read the rule views (k_ knowledge, gap_ gaps, loop_ forecasting cycle, cal_ calibration).
  """

  @doc "Reads messages from `input` until end of file and writes responses to `output`."
  def run(input \\ :stdio, output \\ :stdio) do
    case IO.read(input, :line) do
      :eof ->
        :ok

      {:error, _} ->
        :ok

      line ->
        case handle_line(line) do
          nil -> :ok
          response -> IO.write(output, [Jason.encode_to_iodata!(response), "\n"])
        end

        run(input, output)
    end
  end

  @doc "Handles one line. Returns the response map, or nil for a notification."
  @spec handle_line(String.t()) :: map() | nil
  def handle_line(line) do
    case Jason.decode(String.trim(line)) do
      {:ok, %{} = msg} -> handle(msg)
      {:ok, _} -> error(nil, -32_600, "Invalid Request")
      {:error, _} -> error(nil, -32_700, "Parse error")
    end
  end

  @doc "Handles one decoded JSON-RPC message."
  @spec handle(map()) :: map() | nil
  def handle(%{"method" => "notifications/" <> _}), do: nil
  def handle(%{"id" => id, "method" => "ping"}), do: result(id, %{})

  def handle(%{"id" => id, "method" => "initialize"} = msg) do
    result(id, %{
      "protocolVersion" => get_in(msg, ["params", "protocolVersion"]) || @protocol_version,
      "capabilities" => %{"tools" => %{"listChanged" => false}},
      "serverInfo" => %{
        "name" => "forecast_loop",
        "version" => to_string(Application.spec(:forecast_loop, :vsn))
      },
      "instructions" => @instructions
    })
  end

  def handle(%{"id" => id, "method" => "tools/list"}),
    do: result(id, %{"tools" => Tools.definitions()})

  def handle(%{"id" => id, "method" => "tools/call", "params" => %{"name" => name} = params}) do
    args = Map.get(params, "arguments") || %{}

    {data, is_error} =
      try do
        case Tools.call(name, args) do
          {:ok, data} -> {data, false}
          {:error, reason} -> {%{"error" => reason_text(reason)}, true}
        end
      rescue
        e -> {%{"error" => Exception.message(e)}, true}
      end

    text = Jason.encode!(json_safe(data), pretty: true)
    result(id, %{"content" => [%{"type" => "text", "text" => text}], "isError" => is_error})
  end

  def handle(%{"id" => id, "method" => method}),
    do: error(id, -32_601, "Method not found: #{method}")

  def handle(_msg), do: error(nil, -32_600, "Invalid Request")

  defp result(id, result), do: %{"jsonrpc" => "2.0", "id" => id, "result" => result}

  defp error(id, code, message),
    do: %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}

  defp reason_text(errors) when is_list(errors) or is_map(errors), do: json_safe(errors)
  defp reason_text(reason) when is_binary(reason), do: reason
  defp reason_text(reason), do: inspect(reason)

  # Makes terms JSON-encodable: tuples and atoms other than booleans/nil become text.
  defp json_safe(%DateTime{} = d), do: DateTime.to_iso8601(d)
  defp json_safe(%Date{} = d), do: Date.to_iso8601(d)
  defp json_safe(%Decimal{} = d), do: Decimal.to_float(d)
  defp json_safe(%_{} = s), do: s |> Map.from_struct() |> json_safe()
  defp json_safe(m) when is_map(m), do: Map.new(m, fn {k, v} -> {to_string(k), json_safe(v)} end)
  defp json_safe(l) when is_list(l), do: Enum.map(l, &json_safe/1)
  defp json_safe(t) when is_tuple(t), do: inspect(t)
  defp json_safe(a) when is_atom(a) and a not in [true, false, nil], do: to_string(a)
  defp json_safe(v), do: v
end
