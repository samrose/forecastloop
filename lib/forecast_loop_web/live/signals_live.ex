defmodule ForecastLoopWeb.SignalsLive do
  @moduledoc """
  The signal catalog by domain. Each signal shows a sparkline of its as-of values
  with regime shifts marked, its definition changes (open work items), and what
  consumes it: knowledge-rule rows, derived signals, templates and questions.
  """
  use ForecastLoopWeb, :live_view

  import Ecto.Query
  import ForecastLoopWeb.Charts
  alias ForecastLoop.{Batch, Observations, Repo, Signals}
  alias ForecastLoop.Batch.WorkItem
  alias ForecastLoop.Ledger.{Question, QuestionTemplate}
  alias ForecastLoop.Signals.RegimeShift
  alias ForecastLoop.Sources.Derived

  @impl true
  def mount(_params, _session, socket) do
    as_of = Batch.as_of()
    signals = Signals.list_signals()

    cards =
      Enum.map(signals, fn s ->
        obs = Observations.as_of([s.id], as_of)

        shifts =
          Repo.all(
            from r in RegimeShift,
              where: r.signal_id == ^s.id,
              order_by: r.effective_at,
              select: r.effective_at
          )

        %{
          signal: s,
          count: length(obs),
          points: obs |> Enum.take(-120) |> Enum.map(&{&1.effective_at, &1.value}),
          last: List.last(obs),
          shifts: shifts,
          changes: definition_changes(s.id),
          consumers: consumers(s, signals)
        }
      end)
      |> Enum.group_by(&(&1.signal.domain || "(no domain)"))
      |> Enum.sort()

    {:ok, assign(socket, page_title: "Signals", as_of: as_of, groups: cards)}
  end

  defp definition_changes(id) do
    Repo.all(
      from w in WorkItem,
        where:
          w.status == "open" and w.subject_id == ^to_string(id) and
            (w.kind == "definition_change" or w.subject_type == "gap_definition_change" or
               w.kind == "refresh_failed"),
        select: %{kind: w.kind, payload: w.payload}
    )
  end

  defp consumers(s, all) do
    derived =
      for d <- all,
          d.kind == "derived",
          s.name in Derived.inputs(d.source_spec),
          do: "derived " <> d.name

    id = s.id

    templates =
      Repo.all(from t in QuestionTemplate, select: t)
      |> Enum.filter(&(&1.resolution_condition_pattern["signal"] == s.name))
      |> Enum.map(&("template " <> &1.key))

    questions =
      Repo.aggregate(
        from(q in Question,
          where: fragment("(?->>'signal_id')::bigint = ?", q.resolution_condition, ^id)
        ),
        :count
      )

    rule_rows =
      case Repo.query!(
             "SELECT (SELECT count(*) FROM rules.k_event_entity WHERE signal_id = $1), (SELECT count(*) FROM rules.k_event_class WHERE signal_id = $1)",
             [id]
           ) do
        %{rows: [[e, c]]} -> ["k_event_entity: #{e} rows", "k_event_class: #{c} rows"]
      end

    rule_rows ++
      derived ++ templates ++ if(questions > 0, do: ["#{questions} questions"], else: [])
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.header>
        Signals<:subtitle>
          As of {DateTime.to_iso8601(@as_of)}. Red dashed lines are regime shifts.
        </:subtitle>
      </.header>
      <section :for={{domain, cards} <- @groups} class="space-y-2">
        <h2 class="text-lg font-semibold">{domain}</h2>
        <div
          :for={c <- cards}
          id={"signal-#{c.signal.id}"}
          class="border border-base-300 rounded p-3 flex flex-wrap gap-4"
        >
          <div class="min-w-64">
            <div class="font-semibold">{c.signal.name}</div>
            <div class="text-xs">
              {c.signal.kind} · {c.signal.cadence} · {c.signal.units} · {c.signal.source_spec[
                "system"
              ]}
              <span :if={c.signal.pack}>· pack {c.signal.pack}</span>
            </div>
            <div class="text-xs">
              {c.count} records as of now<span :if={c.last && c.last.value}>, latest {c.last.value}</span>
            </div>
            <div class="text-xs">{c.signal.definition_notes}</div>
          </div>
          <.sparkline points={c.points} shifts={c.shifts} />
          <div class="text-xs">
            <div :if={c.shifts != []}>
              Regime shifts: {Enum.map_join(c.shifts, ", ", &Date.to_iso8601/1)}
            </div>
            <div :for={ch <- c.changes} class="text-warning">
              {ch.kind}: {Jason.encode!(ch.payload)}
            </div>
            <div>Consumed by: {Enum.join(c.consumers, "; ")}</div>
          </div>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
