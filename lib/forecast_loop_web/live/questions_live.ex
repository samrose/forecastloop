defmodule ForecastLoopWeb.QuestionsLive do
  @moduledoc "Questions by domain, status and due date, and a form for a new question with all four FIP fields."
  use ForecastLoopWeb, :live_view

  alias ForecastLoop.Ledger

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Questions",
       filters: %{"status" => "", "domain" => "", "due_before" => ""},
       errors: []
     )
     |> load()}
  end

  defp load(socket) do
    f = socket.assigns.filters

    due =
      case Date.from_iso8601(f["due_before"] || "") do
        {:ok, d} -> DateTime.new!(d, ~T[00:00:00], "Etc/UTC")
        _ -> nil
      end

    questions =
      Ledger.list_questions(
        status: blank(f["status"]),
        domain: blank(f["domain"]),
        due_before: due
      )

    domains =
      Ledger.list_questions()
      |> Enum.map(& &1.domain)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort()

    assign(socket, questions: questions, domains: domains)
  end

  defp blank(""), do: nil
  defp blank(v), do: v

  @impl true
  def handle_event("filter", params, socket),
    do:
      {:noreply,
       socket |> assign(filters: Map.take(params, ~w(status domain due_before))) |> load()}

  def handle_event("create", p, socket) do
    with {:ok, rc} <- Jason.decode(p["resolution_condition"] || ""),
         {:ok, deadline} <- deadline(p["deadline"]),
         {:ok, author} <- Ledger.ensure_agent(p["author"], "human", "ui"),
         {:ok, q} <-
           Ledger.create_question(%{
             title: p["title"],
             event_definition: p["event_definition"],
             resolution_condition: rc,
             deadline: deadline,
             domain: p["domain"],
             created_by_id: author.id,
             asserted_by: "ui:" <> p["author"]
           }) do
      {:noreply, push_navigate(socket, to: ~p"/questions/#{q.id}")}
    else
      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, assign(socket, errors: Enum.map(cs.errors, fn {k, {m, _}} -> "#{k} #{m}" end))}

      {:error, %Jason.DecodeError{}} ->
        {:noreply, assign(socket, errors: ["resolution_condition must be JSON"])}

      {:error, msg} ->
        {:noreply, assign(socket, errors: [to_string(msg)])}
    end
  end

  defp deadline(s) do
    case DateTime.from_iso8601(s || "") do
      {:ok, dt, _} -> {:ok, dt}
      _ -> {:error, "deadline must be an ISO 8601 timestamp, for example 2027-01-01T00:00:00Z"}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.header>Questions</.header>

      <form phx-change="filter" id="filters" class="flex flex-wrap gap-2 text-sm">
        <select name="status" class="select select-sm">
          <option value="">any status</option>
          <option
            :for={s <- ~w(draft review live resolved void)}
            value={s}
            selected={@filters["status"] == s}
          >
            {s}
          </option>
        </select>
        <select name="domain" class="select select-sm">
          <option value="">any domain</option>
          <option :for={d <- @domains} value={d} selected={@filters["domain"] == d}>{d}</option>
        </select>
        <label>due before
        <input type="date" name="due_before" value={@filters["due_before"]} class="input input-sm" /></label>
      </form>

      <.table id="questions" rows={@questions}>
        <:col :let={q} label="Title">
          <.link navigate={~p"/questions/#{q.id}"} class="link">{q.title}</.link>
        </:col>
        <:col :let={q} label="Domain">{q.domain}</:col>
        <:col :let={q} label="Status">{q.status}</:col>
        <:col :let={q} label="Deadline">{q.deadline && DateTime.to_date(q.deadline)}</:col>
      </.table>

      <details class="border border-base-300 rounded p-3">
        <summary class="font-semibold">New question (Forecast Integrity Protocol)</summary>
        <ul :if={@errors != []} class="text-error text-sm">
          <li :for={e <- @errors}>{e}</li>
        </ul>
        <form id="new-question" phx-submit="create" class="grid gap-2 text-sm mt-2">
          <input name="title" placeholder="Title" class="input" required />
          <textarea
            name="event_definition"
            placeholder="Event definition: exactly what counts"
            class="textarea"
          ></textarea>
          <textarea
            name="resolution_condition"
            class="textarea font-mono"
            placeholder={
              ~s({"type":"series","signal_id":1,"op":">=","value":4.5,"at":"end_of_window"})
            }
          ></textarea>
          <input name="deadline" placeholder="Deadline, e.g. 2027-01-01T00:00:00Z" class="input" />
          <input name="domain" placeholder="Domain" class="input" />
          <input name="author" placeholder="Your name (author)" class="input" required />
          <button class="btn btn-primary">Create (goes to review)</button>
        </form>
      </details>
    </Layouts.app>
    """
  end
end
