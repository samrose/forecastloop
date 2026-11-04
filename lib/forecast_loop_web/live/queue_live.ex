defmodule ForecastLoopWeb.QueueLive do
  @moduledoc """
  The work queue: open work items grouped by kind, gaps first. Gap items about an
  unknown entity or an unclassified event have an inline form that asserts a
  knowledge fact. A gap closes when the gap step runs again ("Recheck gaps", or the
  next batch run).
  """
  use ForecastLoopWeb, :live_view

  alias ForecastLoop.{Batch, Knowledge}
  alias ForecastLoop.Batch.{Gaps, NightlyWorker}

  @inline %{
    "gap_unknown_entity" => ~w(entity_attr entity_domain entity_alias),
    "gap_unclassified_event" => ~w(class_rule value_alias entity_alias)
  }

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(page_title: "Queue", author: "") |> load()}
  end

  defp load(socket) do
    groups =
      Batch.list_work_items()
      |> Enum.group_by(& &1.kind)
      |> Enum.sort_by(fn {kind, _} -> {kind != "gap", kind} end)

    assign(socket, groups: groups, inline: @inline)
  end

  @impl true
  def handle_event("set_author", %{"author" => a}, socket),
    do: {:noreply, assign(socket, author: String.trim(a))}

  def handle_event("assert", params, socket) do
    author = if socket.assigns.author == "", do: "ui", else: socket.assigns.author

    with {:ok, attributes} <- decode_attributes(params["attributes"]),
         {:ok, fact} <-
           Knowledge.assert_fact(%{
             predicate: params["predicate"],
             subject: params["subject"],
             object: params["object"],
             attributes: attributes,
             note: "from queue item #{params["item_id"]}",
             asserted_by: "ui:" <> author
           }) do
      {:noreply,
       put_flash(
         socket,
         :info,
         "Asserted #{fact.predicate}(#{fact.subject}, #{fact.object}). Recheck gaps or wait for the next run to close the item."
       )}
    else
      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, put_flash(socket, :error, "Not asserted: #{inspect(cs.errors)}")}

      {:error, msg} ->
        {:noreply, put_flash(socket, :error, msg)}
    end
  end

  def handle_event("status", %{"id" => id, "status" => status}, socket) do
    {:ok, _} =
      Batch.set_work_item_status(String.to_integer(id), status, "ui:" <> socket.assigns.author)

    {:noreply, load(socket)}
  end

  def handle_event("recheck_gaps", _, socket) do
    stats = Gaps.run(nil)

    {:noreply,
     socket
     |> load()
     |> put_flash(:info, "Gaps: #{stats["opened"]} opened, #{stats["closed"]} closed.")}
  end

  def handle_event("run_batch", _, socket) do
    {:ok, _} = Oban.insert(NightlyWorker.new(%{}))
    {:noreply, put_flash(socket, :info, "Batch run queued. See Runs.")}
  end

  defp decode_attributes(nil), do: {:ok, %{}}
  defp decode_attributes(""), do: {:ok, %{}}

  defp decode_attributes(json) do
    case Jason.decode(json) do
      {:ok, m} when is_map(m) -> {:ok, m}
      _ -> {:error, "Attributes must be a JSON object."}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.header>
        Queue
        <:subtitle>Open work items. Gaps first: what the system needs but does not have.</:subtitle>
        <:actions>
          <.button phx-click="recheck_gaps">Recheck gaps</.button>
          <.button phx-click="run_batch">Run batch now</.button>
        </:actions>
      </.header>

      <form id="acting-as" phx-change="set_author" class="flex gap-2 items-center text-sm">
        <label for="author">Acting as</label>
        <input
          id="author"
          name="author"
          value={@author}
          class="input input-sm"
          placeholder="your name"
        />
      </form>

      <p :if={@groups == []}>No open work items.</p>

      <section :for={{kind, items} <- @groups} id={"kind-#{kind}"} class="space-y-2">
        <h2 class="text-lg font-semibold">{kind} <span class="badge">{length(items)}</span></h2>
        <div
          :for={item <- items}
          id={"item-#{item.id}"}
          class="border border-base-300 rounded p-3 space-y-2"
        >
          <div class="flex justify-between gap-4">
            <div>
              <span class="font-mono text-sm">{item.subject_type}</span>
              <span class="font-semibold">{item.subject_id}</span>
            </div>
            <div class="flex gap-1">
              <button
                class="btn btn-xs"
                phx-click="status"
                phx-value-id={item.id}
                phx-value-status="done"
              >Done</button>
              <button
                class="btn btn-xs"
                phx-click="status"
                phx-value-id={item.id}
                phx-value-status="dismissed"
              >Dismiss</button>
            </div>
          </div>
          <pre class="text-xs whitespace-pre-wrap">{Jason.encode!(item.payload, pretty: true)}</pre>
          <form
            :if={Map.has_key?(@inline, item.subject_type)}
            id={"assert-#{item.id}"}
            phx-submit="assert"
            class="flex flex-wrap gap-2 items-end text-sm"
          >
            <input type="hidden" name="item_id" value={item.id} />
            <label>
              Predicate
              <select name="predicate" class="select select-sm">
                <option :for={p <- @inline[item.subject_type]} value={p}>{p}</option>
              </select>
            </label>
            <label>
              Subject <input name="subject" value={default_subject(item)} class="input input-sm" />
            </label>
            <label>Object <input name="object" class="input input-sm" placeholder="e.g. owner=team" /></label>
            <label>
              Attributes (JSON)
              <input name="attributes" class="input input-sm" placeholder={~s({"equals": "x"})} />
            </label>
            <button class="btn btn-sm btn-primary">Assert fact</button>
          </form>
        </div>
      </section>
    </Layouts.app>
    """
  end

  defp default_subject(%{subject_type: "gap_unknown_entity", subject_id: entity}), do: entity
  defp default_subject(_item), do: ""
end
