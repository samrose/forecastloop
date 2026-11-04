defmodule Mix.Tasks.ForecastLoop.Mcp do
  @shortdoc "Runs the MCP server on stdio"
  @moduledoc """
  Runs ForecastLoop's Model Context Protocol server on stdin/stdout, for Claude.
  The batch queue and cron do not run in this process. Logs go to stderr.
  Run `mix compile` first: Mix prints compiler output to stdout, which an MCP
  client would read as a protocol message.

      mix forecast_loop.mcp

  Claude Code configuration (`.mcp.json` in the project root):

      {"mcpServers": {"forecast_loop": {"command": "nix",
        "args": ["develop", "-c", "mix", "forecast_loop.mcp"]}}}
  """
  use Mix.Task

  alias ForecastLoop.MCP.Server

  @impl Mix.Task
  def run(_args) do
    oban = Application.get_env(:forecast_loop, Oban, [])
    Application.put_env(:forecast_loop, Oban, Keyword.merge(oban, queues: false, plugins: false))
    Mix.Task.run("app.start")

    # stdout carries only protocol messages. The standard handler cannot change its
    # device after it starts, and app.start configures it, so replace it here with
    # one that writes to stderr.
    :ok = :logger.remove_handler(:default)

    :ok =
      :logger.add_handler(:default, :logger_std_h, %{
        config: %{type: :standard_error},
        formatter: Logger.default_formatter()
      })

    Server.run()
  end
end
