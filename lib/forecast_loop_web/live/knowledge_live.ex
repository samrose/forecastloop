defmodule ForecastLoopWeb.KnowledgeLive do
  @moduledoc "Knowledge facts by predicate and domain, with validity ranges; inline edit, delete and add."
  use ForecastLoopWeb, :live_view

  alias ForecastLoop.Knowledge
  alias ForecastLoop.Knowledge.Fact
  alias ForecastLoop.Sources.Mapping

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Knowledge",
       predicate: "",
       domain: "",
       editing: nil,
       predicates: Fact.predicates()
     )
     |> load()}
  end

  defp load(socket) do
    a = socket.assigns
    facts = Knowledge.list_facts(predicate: blank(a.predicate), domain: blank(a.domain))

    domains =
      Knowledge.list_facts()
      |> Enum.map(& &1.domain)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort()

    assign(socket, facts: facts, domains: domains)
  end

  defp blank(""), do: nil
  defp blank(v), do: v

  @impl true
  def handle_event("filter", p, socket),
    do:
      {:noreply,
       socket |> assign(predicate: p["predicate"] || "", domain: p["domain"] || "") |> load()}

  def handle_event("edit", %{"id" => id}, socket),
    do: {:noreply, assign(socket, editing: String.to_integer(id))}

  def handle_event("cancel", _, socket), do: {:noreply, assign(socket, editing: nil)}

  def handle_event("save", %{"fact_id" => id} = p, socket) do
    fact = Knowledge.get_fact!(String.to_integer(id))

    with {:ok, attrs} <- attrs(p),
         {:ok, _} <- Knowledge.update_fact(fact, Map.put(attrs, "asserted_by", "ui")) do
      {:noreply,
       socket
       |> assign(editing: nil)
       |> load()
       |> put_flash(
         :info,
         "Saved. Rules use the change at once; open gaps close on the next run."
       )}
    else
      {:error, msg} -> {:noreply, put_flash(socket, :error, error_text(msg))}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    {:ok, _} = id |> String.to_integer() |> Knowledge.get_fact!() |> Knowledge.delete_fact()
    {:noreply, load(socket)}
  end

  def handle_event("add", p, socket) do
    with {:ok, attrs} <- attrs(p),
         {:ok, _} <-
           Knowledge.assert_fact(
             Map.merge(attrs, %{
               "predicate" => p["predicate"],
               "subject" => p["subject"],
               "asserted_by" => "ui"
             })
           ) do
      {:noreply, socket |> load() |> put_flash(:info, "Fact asserted.")}
    else
      {:error, msg} -> {:noreply, put_flash(socket, :error, error_text(msg))}
    end
  end

  defp attrs(p) do
    with {:ok, attributes} <- json(p["attributes"]),
         {:ok, vf} <- time(p["valid_from"]),
         {:ok, vt} <- time(p["valid_to"]) do
      {:ok,
       %{
         "object" => p["object"],
         "attributes" => attributes,
         "valid_from" => vf,
         "valid_to" => vt,
         "domain" => blank(p["domain"] || ""),
         "note" => p["note"]
       }}
    end
  end

  defp json(s) when s in [nil, ""], do: {:ok, %{}}

  defp json(s) do
    case Jason.decode(s) do
      {:ok, m} when is_map(m) -> {:ok, m}
      _ -> {:error, "attributes must be a JSON object"}
    end
  end

  defp time(s) when s in [nil, ""], do: {:ok, nil}

  defp time(s) do
    case Mapping.parse_time(s, "iso8601") do
      {:ok, t} -> {:ok, t}
      _ -> {:error, "#{s} is not an ISO 8601 date or timestamp"}
    end
  end

  defp error_text(%Ecto.Changeset{} = cs),
    do: Enum.map_join(cs.errors, "; ", fn {k, {m, _}} -> "#{k} #{m}" end)

  defp error_text(msg), do: to_string(msg)

  defp d(nil), do: ""
  defp d(t), do: t |> DateTime.to_date() |> Date.to_iso8601()

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.header>
        Knowledge
        <:subtitle>
          Hand-asserted facts. A fact applies in [valid from, valid to). Packs supply rows for these predicates only.
        </:subtitle>
      </.header>

      <form phx-change="filter" id="knowledge-filter" class="flex gap-2 text-sm">
        <select name="predicate" class="select select-sm">
          <option value="">any predicate</option>
          <option :for={p <- @predicates} value={p} selected={p == @predicate}>{p}</option>
        </select>
        <select name="domain" class="select select-sm">
          <option value="">any domain</option>
          <option :for={dm <- @domains} value={dm} selected={dm == @domain}>{dm}</option>
        </select>
      </form>

      <table class="table table-sm" id="facts">
        <thead>
          <tr>
            <th>Predicate</th><th>Subject</th><th>Object</th><th>Attributes</th><th>Valid from</th><th>
              Valid to
            </th><th>Domain</th><th>Pack</th><th></th>
          </tr>
        </thead>
        <tbody>
          <%= for f <- @facts do %>
            <tr :if={@editing != f.id} id={"fact-#{f.id}"}>
              <td>{f.predicate}</td><td>{f.subject}</td><td>{f.object}</td>
              <td class="font-mono text-xs">
                {if f.attributes != %{}, do: Jason.encode!(f.attributes)}
              </td>
              <td>{d(f.valid_from)}</td><td>{d(f.valid_to)}</td><td>{f.domain}</td><td>{f.pack}</td>
              <td class="whitespace-nowrap">
                <button class="btn btn-xs" phx-click="edit" phx-value-id={f.id}>Edit</button>
                <button
                  class="btn btn-xs"
                  phx-click="delete"
                  phx-value-id={f.id}
                  data-confirm="Delete this fact?"
                >Delete</button>
              </td>
            </tr>
            <tr :if={@editing == f.id} id={"fact-#{f.id}-edit"}>
              <td colspan="9">
                <form id={"edit-#{f.id}"} phx-submit="save" class="flex flex-wrap gap-2 text-sm">
                  <input type="hidden" name="fact_id" value={f.id} />
                  <span class="font-semibold">{f.predicate}({f.subject},</span>
                  <input name="object" value={f.object} class="input input-sm" />)
                  <input
                    name="attributes"
                    value={if f.attributes != %{}, do: Jason.encode!(f.attributes)}
                    class="input input-sm font-mono"
                    placeholder="{}"
                  />
                  <input
                    name="valid_from"
                    value={d(f.valid_from)}
                    class="input input-sm"
                    placeholder="valid from"
                  />
                  <input
                    name="valid_to"
                    value={d(f.valid_to)}
                    class="input input-sm"
                    placeholder="valid to"
                  />
                  <input name="domain" value={f.domain} class="input input-sm" placeholder="domain" />
                  <input name="note" value={f.note} class="input input-sm" placeholder="note" />
                  <button class="btn btn-sm btn-primary">Save</button>
                  <button type="button" class="btn btn-sm" phx-click="cancel">Cancel</button>
                </form>
              </td>
            </tr>
          <% end %>
        </tbody>
      </table>

      <form
        id="add-fact"
        phx-submit="add"
        class="flex flex-wrap gap-2 text-sm border border-base-300 rounded p-3"
      >
        <select name="predicate" class="select select-sm">
          <option :for={p <- @predicates} value={p}>{p}</option>
        </select>
        <input name="subject" placeholder="subject" class="input input-sm" required />
        <input name="object" placeholder="object" class="input input-sm" required />
        <input name="attributes" placeholder="attributes JSON" class="input input-sm font-mono" />
        <input name="valid_from" placeholder="valid from" class="input input-sm" />
        <input name="valid_to" placeholder="valid to" class="input input-sm" />
        <input name="domain" placeholder="domain" class="input input-sm" />
        <input name="note" placeholder="note" class="input input-sm" />
        <button class="btn btn-sm btn-primary">Add fact</button>
      </form>
    </Layouts.app>
    """
  end
end
