defmodule ForecastLoopWeb.PackLive do
  @moduledoc """
  The pack builder for one pack (docs/adr/0009):

    1. the pack's name and purpose (made on the Packs page);
    2. add a signal from a generic source, after a preview;
    3. answer the gap questions in the Queue (each answer is a knowledge fact);
    4. add question templates and scenarios;
    5. export the pack to a folder.
  """
  use ForecastLoopWeb, :live_view

  import Ecto.Query
  alias ForecastLoop.{Batch, Knowledge, Ledger, Packs, Repo, Signals, Sources}
  alias ForecastLoop.Ledger.{QuestionTemplate, Scenario}

  @impl true
  def mount(%{"name" => name}, _session, socket) do
    case Packs.get_pack(name) do
      nil ->
        {:ok, socket |> put_flash(:error, "No pack #{name}") |> push_navigate(to: ~p"/packs")}

      pack ->
        {:ok,
         socket
         |> assign(pack: pack, page_title: "Pack " <> name, preview: nil, export_dir: nil)
         |> load()}
    end
  end

  defp load(socket) do
    name = socket.assigns.pack.name

    assign(socket,
      contributions: Packs.contributions(name),
      signals: Signals.list_signals(pack: name),
      facts: Knowledge.list_facts(pack: name),
      templates: Repo.all(from t in QuestionTemplate, where: t.pack == ^name, order_by: t.key),
      scenarios:
        Repo.all(
          from s in Scenario, where: s.pack == ^name, order_by: s.id, preload: :assumptions
        ),
      open_gaps: length(Batch.list_work_items(kind: "gap")),
      systems: Sources.list()
    )
  end

  @impl true
  def handle_event("preview", p, socket) do
    case Jason.decode(p["source_spec"] || "") do
      {:ok, spec} ->
        result =
          case Sources.preview(spec) do
            {:ok, rows} -> {:ok, rows}
            {:error, reason} -> {:error, inspect(reason)}
          end

        {:noreply, assign(socket, preview: result)}

      _ ->
        {:noreply, assign(socket, preview: {:error, "source_spec must be JSON"})}
    end
  end

  def handle_event("add_signal", p, socket) do
    with {:ok, spec} <- decode(p["source_spec"]),
         {:ok, s} <-
           Signals.register_signal(%{
             name: p["name"],
             kind: p["kind"],
             domain: p["domain"],
             cadence: p["cadence"],
             units: p["units"],
             source_spec: spec,
             pack: socket.assigns.pack.name,
             asserted_by: "ui:builder"
           }) do
      {:noreply,
       socket
       |> load()
       |> assign(preview: nil)
       |> put_flash(
         :info,
         "Signal #{s.name} added. The next batch run fetches it and opens gap questions."
       )}
    else
      {:error, e} -> {:noreply, put_flash(socket, :error, error_text(e))}
    end
  end

  def handle_event("add_template", p, socket) do
    with {:ok, rc} <- decode(p["resolution_condition_pattern"]),
         {:ok, params} <- decode(blank_json(p["params"])),
         {:ok, author} <- Ledger.ensure_agent("pack:" <> socket.assigns.pack.name, "model", "ui"),
         {:ok, t} <-
           Ledger.create_template(%{
             key: p["key"],
             domain: p["domain"],
             title_pattern: p["title_pattern"],
             event_definition_pattern: p["event_definition_pattern"],
             resolution_condition_pattern: rc,
             cadence: p["cadence"],
             window_length: p["window_length"],
             params: params,
             starts_on: p["starts_on"],
             created_by_id: author.id,
             pack: socket.assigns.pack.name,
             asserted_by: "ui:builder"
           }) do
      {:noreply, socket |> load() |> put_flash(:info, "Template #{t.key} added.")}
    else
      {:error, e} -> {:noreply, put_flash(socket, :error, error_text(e))}
    end
  end

  def handle_event("add_scenario", p, socket) do
    {:ok, s} =
      Ledger.create_scenario(%{
        title: p["title"],
        narrative: p["narrative"] || "",
        domain: p["domain"],
        pack: socket.assigns.pack.name,
        asserted_by: "ui:builder"
      })

    for line <- String.split(p["assumptions"] || "", "\n", trim: true), String.trim(line) != "" do
      {:ok, _} =
        Ledger.create_assumption(%{
          scenario_id: s.id,
          statement: String.trim(line),
          asserted_by: "ui:builder"
        })
    end

    {:noreply, socket |> load() |> put_flash(:info, "Scenario added.")}
  end

  def handle_event("export", _, socket) do
    dir =
      Path.join(
        Application.get_env(:forecast_loop, :runs_dir, "priv/runs"),
        "../packs_export/#{socket.assigns.pack.name}"
      )
      |> Path.expand()

    :ok = Packs.export(socket.assigns.pack.name, dir)
    {:noreply, assign(socket, export_dir: dir)}
  end

  defp decode(json) do
    case Jason.decode(json || "") do
      {:ok, m} when is_map(m) -> {:ok, m}
      _ -> {:error, "expected a JSON object"}
    end
  end

  defp blank_json(s) when s in [nil, ""], do: "{}"
  defp blank_json(s), do: s

  defp error_text(%Ecto.Changeset{} = cs),
    do: Enum.map_join(cs.errors, "; ", fn {k, {m, _}} -> "#{k} #{m}" end)

  defp error_text(e), do: to_string(e)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.header>
        {@pack.title}
        <:subtitle>{@pack.name} · {@pack.origin} · {@pack.status}. {@pack.description}</:subtitle>
        <:actions><.button phx-click="export">Export to folder</.button></:actions>
      </.header>
      <p :if={@export_dir} id="exported" class="text-sm">Exported to <code>{@export_dir}</code>.</p>

      <p class="text-sm" id="contributions">
        Contributes: {@contributions |> Enum.map_join(", ", fn {t, n} -> "#{n} #{t}" end)}
      </p>

      <section class="border border-base-300 rounded p-3 space-y-2">
        <h2 class="font-semibold">Step 2: add a signal</h2>
        <p class="text-sm">
          Sources:
          <span :for={s <- @systems} class="badge badge-sm" title={s.description}>{s.system}</span>
        </p>
        <form id="add-signal" phx-submit="add_signal" class="grid gap-2 text-sm">
          <div class="flex flex-wrap gap-2">
            <input name="name" placeholder="name" class="input input-sm" required />
            <select name="kind" class="select select-sm"><option
              :for={k <- ~w(series events derived)}
              value={k}
            >
              {k}
            </option></select>
            <input name="domain" placeholder="domain" class="input input-sm" />
            <input name="cadence" placeholder="cadence (monthly)" class="input input-sm" />
            <input name="units" placeholder="units" class="input input-sm" />
          </div>
          <textarea
            name="source_spec"
            class="textarea font-mono"
            rows="4"
            placeholder={
              ~s({"system":"http_csv","url":"https://...","fields":{"effective_at":"DATE","value":"VALUE"},"date_format":"ymd","entity_attributes":[]})
            }
          ></textarea>
          <button class="btn btn-sm btn-primary w-fit">Register signal</button>
        </form>
        <form id="preview" phx-submit="preview" class="grid gap-2 text-sm">
          <textarea
            name="source_spec"
            class="textarea font-mono"
            rows="2"
            placeholder="Paste a source spec here to preview its rows before you register it"
          ></textarea>
          <button class="btn btn-sm w-fit">Preview spec</button>
        </form>
        <div :if={@preview} id="preview-result" class="text-xs">
          <%= case @preview do %>
            <% {:ok, rows} -> %>
              <p>{length(rows)} rows (first 20):</p>
              <pre class="whitespace-pre-wrap">{Enum.map_join(rows, "\n", &"#{&1.source_record_id}  #{&1.effective_at}  #{inspect(&1.value)}  #{Jason.encode!(&1.attributes)}")}</pre>
            <% {:error, msg} -> %>
              <p class="text-error">Preview failed: {msg}</p>
          <% end %>
        </div>
        <ul class="text-sm">
          <li :for={s <- @signals}>{s.name} ({s.kind}, {s.source_spec["system"]})</li>
        </ul>
      </section>

      <section class="border border-base-300 rounded p-3">
        <h2 class="font-semibold">Step 3: answer the gap questions</h2>
        <p class="text-sm">
          After a batch run, the gap rules list what the pack still needs (unknown entities, unclassified events, missing history). {@open_gaps} gap items are open. <.link
            navigate={~p"/queue"}
            class="link"
          >Open the Queue</.link>.
          The pack has {length(@facts)} knowledge facts.
        </p>
      </section>

      <section class="border border-base-300 rounded p-3 space-y-2">
        <h2 class="font-semibold">Step 4: templates and scenarios</h2>
        <ul class="text-sm">
          <li :for={t <- @templates}>{t.key}: {t.title_pattern}</li>
        </ul>
        <form id="add-template" phx-submit="add_template" class="grid gap-2 text-sm">
          <div class="flex flex-wrap gap-2">
            <input name="key" placeholder="key" class="input input-sm" required />
            <input name="domain" placeholder="domain" class="input input-sm" required />
            <select name="cadence" class="select select-sm"><option
              :for={c <- ~w(monthly quarterly weekly)}
              value={c}
            >
              {c}
            </option></select>
            <input name="window_length" placeholder="P1M" class="input input-sm" required />
            <input name="starts_on" type="date" class="input input-sm" required />
          </div>
          <input
            name="title_pattern"
            placeholder="Title with {{period}} and {{param.x}}"
            class="input"
            required
          />
          <textarea
            name="event_definition_pattern"
            placeholder="Event definition pattern"
            class="textarea"
            required
          ></textarea>
          <textarea
            name="resolution_condition_pattern"
            class="textarea font-mono"
            placeholder={
              ~s({"type":"series","signal":"name","op":">","value":"{{param.x}}","at":"end_of_window"})
            }
          ></textarea>
          <input name="params" placeholder={~s({"x": 4.5})} class="input font-mono" />
          <button class="btn btn-sm btn-primary w-fit">Add template</button>
        </form>

        <ul class="text-sm">
          <li :for={s <- @scenarios}>{s.title} ({length(s.assumptions)} assumptions)</li>
        </ul>
        <form id="add-scenario" phx-submit="add_scenario" class="grid gap-2 text-sm">
          <input name="title" placeholder="Scenario title" class="input" required />
          <input name="domain" placeholder="domain" class="input" />
          <textarea name="narrative" placeholder="Narrative" class="textarea"></textarea>
          <textarea name="assumptions" placeholder="One assumption on each line" class="textarea"></textarea>
          <button class="btn btn-sm btn-primary w-fit">Add scenario</button>
        </form>
      </section>
    </Layouts.app>
    """
  end
end
