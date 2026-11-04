defmodule ForecastLoopWeb.PacksLive do
  @moduledoc "Installed packs and what each contributed; pack folders to install; the start of the pack builder."
  use ForecastLoopWeb, :live_view

  alias ForecastLoop.Packs

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket |> assign(page_title: "Packs") |> load()}

  defp load(socket) do
    installed = Packs.list_packs()
    names = Enum.map(installed, & &1.pack.name)
    assign(socket, installed: installed, available: Packs.available() -- names)
  end

  @impl true
  def handle_event("install", %{"name" => name}, socket) do
    case Packs.install(name, asserted_by: "ui") do
      {:ok, s} ->
        {:noreply, socket |> load() |> put_flash(:info, "Installed #{name}: #{Jason.encode!(s)}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Install failed: #{inspect(reason)}")}
    end
  end

  def handle_event("create", p, socket) do
    case Packs.create_pack(%{
           name: p["name"],
           title: p["title"],
           description: p["description"] || "",
           asserted_by: "ui:" <> (p["author"] || "")
         }) do
      {:ok, pack} ->
        {:noreply, push_navigate(socket, to: ~p"/packs/#{pack.name}")}

      {:error, cs} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           Enum.map_join(cs.errors, "; ", fn {k, {m, _}} -> "#{k} #{m}" end)
         )}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.header>
        Packs<:subtitle>
          A domain pack gives the domain-neutral core its meaning: signals, knowledge, templates, models and scenarios.
        </:subtitle>
      </.header>

      <.table id="installed" rows={@installed}>
        <:col :let={p} label="Pack">
          <.link navigate={~p"/packs/#{p.pack.name}"} class="link">{p.pack.name}</.link>
        </:col>
        <:col :let={p} label="Title">{p.pack.title}</:col>
        <:col :let={p} label="Origin">{p.pack.origin} · {p.pack.status}</:col>
        <:col :let={p} label="Contributed">
          {p.contributions
          |> Enum.filter(fn {_, n} -> n > 0 end)
          |> Enum.map_join(", ", fn {t, n} -> "#{n} #{t}" end)}
        </:col>
      </.table>

      <section :if={@available != []} id="available">
        <h2 class="font-semibold">Folders to install</h2>
        <div :for={name <- @available} class="flex gap-2 items-center">
          <span>{name}</span>
          <button class="btn btn-sm" phx-click="install" phx-value-name={name}>Install</button>
        </div>
      </section>

      <form
        id="new-pack"
        phx-submit="create"
        class="grid gap-2 text-sm border border-base-300 rounded p-3"
      >
        <h2 class="font-semibold">Build a new pack</h2>
        <p>
          Name it and say what it forecasts. Then add signals from generic sources, answer the gap questions in the Queue, and add templates and scenarios.
        </p>
        <input name="name" placeholder="name (lowercase, underscores)" class="input" required />
        <input name="title" placeholder="title" class="input" required />
        <textarea name="description" placeholder="What does this pack forecast?" class="textarea"></textarea>
        <input name="author" placeholder="your name" class="input" />
        <button class="btn btn-primary">Create pack</button>
      </form>
    </Layouts.app>
    """
  end
end
