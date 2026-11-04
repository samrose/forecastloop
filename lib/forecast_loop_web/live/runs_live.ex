defmodule ForecastLoopWeb.RunsLive do
  @moduledoc "Batch run history with the counts of each step, and each run's knowledge snapshot directory."
  use ForecastLoopWeb, :live_view

  alias ForecastLoop.Batch
  alias ForecastLoop.Batch.{NightlyWorker, Snapshot}

  @steps ~w(refresh snapshot derive changepoints templates gaps act)

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(page_title: "Runs", steps: @steps, open: nil) |> load()}
  end

  defp load(socket), do: assign(socket, runs: Batch.list_runs(100))

  @impl true
  def handle_event("run", _, socket) do
    {:ok, _} = Oban.insert(NightlyWorker.new(%{}))
    {:noreply, put_flash(socket, :info, "Batch run queued.")}
  end

  def handle_event("refresh", _, socket), do: {:noreply, load(socket)}

  def handle_event("open", %{"id" => id}, socket) do
    id = String.to_integer(id)
    {:noreply, assign(socket, open: if(socket.assigns.open == id, do: nil, else: id))}
  end

  defp files(run_id) do
    dir = Snapshot.dir(run_id)

    case File.ls(dir) do
      {:ok, names} -> {dir, Enum.sort(names)}
      _ -> {dir, []}
    end
  end

  defp summary(stats, "act") when is_map(stats),
    do:
      "promoted #{stats["promoted"]}, resolved #{stats["resolved"]}, forecasts #{get_in(stats, ["forecasts", "made"])}"

  defp summary(%{"error" => e}, _), do: "error: " <> e

  defp summary(stats, _) when is_map(stats),
    do:
      stats
      |> Enum.reject(fn {_, v} -> is_map(v) end)
      |> Enum.map_join(", ", fn {k, v} -> "#{k} #{v}" end)

  defp summary(_, _), do: ""

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.header>
        Runs
        <:actions>
          <.button phx-click="refresh">Refresh</.button>
          <.button phx-click="run">Run batch now</.button>
        </:actions>
      </.header>
      <table class="table table-sm" id="runs">
        <thead>
          <tr>
            <th>Run</th><th>As of</th><th>Status</th><th>Started</th><th :for={s <- @steps}>{s}</th>
          </tr>
        </thead>
        <tbody>
          <%= for r <- @runs do %>
            <tr id={"run-#{r.id}"}>
              <td><button class="link" phx-click="open" phx-value-id={r.id}>{r.id}</button></td>
              <td>{DateTime.to_iso8601(r.as_of)}</td>
              <td>{r.status}</td>
              <td>{DateTime.to_iso8601(r.started_at)}</td>
              <td :for={s <- @steps} class="text-xs">{summary(r.stats[s], s)}</td>
            </tr>
            <tr :if={@open == r.id} id={"run-#{r.id}-detail"}>
              <td colspan={4 + length(@steps)}>
                <% {dir, names} = files(r.id) %>
                <p class="text-sm">Knowledge snapshot: <code>{dir}</code></p>
                <ul class="text-xs">
                  <li :for={n <- names}>{n}</li>
                </ul>
                <pre class="text-xs whitespace-pre-wrap">{Jason.encode!(r.stats, pretty: true)}</pre>
              </td>
            </tr>
          <% end %>
        </tbody>
      </table>
    </Layouts.app>
    """
  end
end
