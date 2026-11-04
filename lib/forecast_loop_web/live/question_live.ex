defmodule ForecastLoopWeb.QuestionLive do
  @moduledoc """
  One question: its FIP fields, every agent's forecast history, the resolution and
  its evidence, the review form, and the forecast entry form (probability slider,
  rationale, cited signals).
  """
  use ForecastLoopWeb, :live_view

  alias ForecastLoop.{Explain, Ledger, Repo, Signals}
  alias ForecastLoop.Signals.Signal

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    {:ok,
     socket
     |> assign(id: String.to_integer(id), probability: 50, signals: Signals.list_signals())
     |> load()}
  end

  defp load(socket) do
    q = Ledger.get_question_with_history!(socket.assigns.id)
    history = q.forecasts |> Enum.group_by(& &1.agent.name) |> Enum.sort()
    rc = q.resolution_condition || %{}
    signal = if is_integer(rc["signal_id"]), do: Repo.get(Signal, rc["signal_id"])
    evidence = (q.resolution && q.resolution.evidence) || %{}

    assign(socket,
      q: q,
      history: history,
      page_title: q.title,
      signal: signal,
      condition_text: Explain.condition(rc, signal),
      results: Explain.results(q),
      value_used: q.resolution && Explain.value_used(rc, evidence, signal),
      points: if(q.resolution, do: Explain.evidence_points(rc, evidence, signal), else: [])
    )
  end

  @impl true
  def handle_event("slide", %{"probability" => p}, socket),
    do: {:noreply, assign(socket, probability: String.to_integer(p))}

  def handle_event("forecast", p, socket) do
    with {:ok, agent} <- Ledger.ensure_agent(p["agent"], "human", "ui"),
         {:ok, _} <-
           Ledger.submit_forecast(%{
             question_id: socket.assigns.q.id,
             agent_id: agent.id,
             probability: String.to_integer(p["probability"]) / 100,
             rationale: p["rationale"] || "",
             cited_signal_ids: p |> Map.get("cited", []) |> Enum.map(&String.to_integer/1),
             asserted_by: "ui:" <> p["agent"]
           }) do
      {:noreply, socket |> load() |> put_flash(:info, "Forecast recorded.")}
    else
      {:error, cs} -> {:noreply, put_flash(socket, :error, "Not recorded: #{inspect(cs.errors)}")}
    end
  end

  def handle_event("review", %{"reviewer" => name}, socket) do
    q = socket.assigns.q
    {:ok, reviewer} = Ledger.ensure_agent(name, "human", "ui")

    if reviewer.id == q.created_by_id do
      {:noreply, put_flash(socket, :error, "The reviewer must not be the author.")}
    else
      {:ok, _} = Ledger.review_question(Ledger.get_question!(q.id), reviewer, "ui:" <> name)

      {:noreply,
       socket
       |> load()
       |> put_flash(:info, "Reviewed. The next batch run makes the question live.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.header>
        {@q.title}
        <:subtitle>
          {@q.domain} · {@q.status} · deadline {@q.deadline && DateTime.to_iso8601(@q.deadline)}
        </:subtitle>
      </.header>

      <.list>
        <:item title="Event definition">{@q.event_definition}</:item>
        <:item title="Resolution condition">
          <p id="condition-text">{@condition_text}</p>
          <p :if={@signal} class="text-sm">
            Signal:
            <.link navigate={~p"/signals" <> "#signal-#{@signal.id}"} class="link">
              {@signal.name}
            </.link>
          </p>
          <details class="text-xs">
            <summary>Stored condition (JSON)</summary>
            <code>{Jason.encode!(@q.resolution_condition)}</code>
          </details>
        </:item>
        <:item title="Author">{@q.created_by && @q.created_by.name}</:item>
        <:item title="Reviewer">{(@q.reviewed_by && @q.reviewed_by.name) || "none yet"}</:item>
      </.list>

      <form :if={@q.status == "review"} id="review" phx-submit="review" class="flex gap-2 text-sm">
        <input
          name="reviewer"
          placeholder="Reviewer name (not the author)"
          class="input input-sm"
          required
        />
        <button class="btn btn-sm">Record review</button>
      </form>

      <section
        :if={@q.resolution}
        id="result-summary"
        class="border border-base-300 rounded p-3 space-y-1"
      >
        <h2 class="font-semibold">
          Outcome: {if @q.resolution.outcome, do: "TRUE", else: "FALSE"}
        </h2>
        <p :if={@results == []} class="text-sm">
          No forecast was made before the resolution, so no forecast has a score.
        </p>
        <p :for={r <- @results} id={"result-#{r.agent}"} class="text-sm">
          <strong>{r.agent}</strong> said {round(r.probability * 100)}% TRUE, so {r.lean}.
          Brier score {Float.round(r.brier, 2)}, {r.verdict}.
        </p>
        <p :if={@results != []} class="text-xs opacity-70">
          The Brier score is the squared gap between the forecast probability and the outcome
          (TRUE = 1, FALSE = 0). 0 is perfect, 0.25 is the score of a 50% guess, and 1 is fully wrong.
          Only each agent's last forecast before the resolution counts.
        </p>
      </section>

      <section
        :if={@q.resolution}
        id="resolution"
        class="border border-base-300 rounded p-3 space-y-2"
      >
        <h2 class="font-semibold">Evidence</h2>
        <p class="text-sm">
          Resolved by {@q.resolution.resolved_by} on {DateTime.to_iso8601(@q.resolution.resolved_at)} ({@q.resolution.source}).
        </p>
        <p :if={@value_used} id="value-used" class="text-sm">{@value_used}</p>
        <div :if={@points != []} id="evidence-inputs" class="text-sm">
          <.evidence_point :for={pt <- @points} point={pt} signal={@signal} />
        </div>
        <details class="text-xs">
          <summary>Stored evidence (JSON)</summary>
          <pre class="whitespace-pre-wrap">{Jason.encode!(@q.resolution.evidence, pretty: true)}</pre>
        </details>
      </section>

      <section id="history">
        <h2 class="text-lg font-semibold">Forecast history</h2>
        <p :if={@history == []} class="text-sm">No forecasts yet.</p>
        <div :for={{agent, forecasts} <- @history} class="mb-2">
          <h3 class="font-semibold">{agent}</h3>
          <.table id={"history-#{agent}"} rows={forecasts}>
            <:col :let={f} label="Made at">{DateTime.to_iso8601(f.made_at)}</:col>
            <:col :let={f} label="P(true)">{Float.round(f.probability, 3)}</:col>
            <:col :let={f} label="Rationale">{f.rationale}</:col>
          </.table>
        </div>
      </section>

      <form
        :if={@q.status == "live"}
        id="forecast"
        phx-submit="forecast"
        phx-change="slide"
        class="grid gap-2 text-sm border border-base-300 rounded p-3"
      >
        <h2 class="font-semibold">Forecast entry</h2>
        <label>
          Probability that this resolves true: <strong>{@probability}%</strong>
          <input type="range" name="probability" min="0" max="100" value={@probability} class="range" />
        </label>
        <textarea name="rationale" placeholder="Rationale" class="textarea"></textarea>
        <label>
          Cited signals
          <select name="cited[]" multiple class="select h-24">
            <option :for={s <- @signals} value={s.id}>{s.name}</option>
          </select>
        </label>
        <input name="agent" placeholder="Your name" class="input" required />
        <button class="btn btn-primary">Record forecast</button>
      </form>
    </Layouts.app>
    """
  end

  attr :point, :map, required: true
  attr :signal, :any, required: true

  # One value with the input values it was computed from, nested.
  defp evidence_point(assigns) do
    ~H"""
    <div class="evidence-point">
      <p>
        <span class="font-mono">{@signal.name}</span>
        for <strong>{@point.label}</strong>: {Explain.number(@point.value)}
      </p>
      <div :for={g <- @point.inputs} class="ml-5 border-l border-base-300 pl-3">
        <p class="opacity-70">
          Computed from <.link navigate={~p"/signals" <> "#signal-#{g.signal.id}"} class="link">
            {g.signal.name}
          </.link>, {g.note}:
        </p>
        <.evidence_point :for={pt <- g.points} point={pt} signal={g.signal} />
        <p :if={g.more > 0} class="opacity-70">and {g.more} more</p>
      </div>
    </div>
    """
  end
end
