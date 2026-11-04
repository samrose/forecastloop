defmodule ForecastLoopWeb.CalibrationLive do
  @moduledoc """
  Calibration per agent and domain, from `rules.cal_summary` and `rules.cal_bucket`
  as of `batch_context.as_of`: mean Brier and log score, skill against the base rate,
  the Murphy decomposition, and a reliability diagram with bin counts.
  """
  use ForecastLoopWeb, :live_view

  import ForecastLoopWeb.Charts
  alias ForecastLoop.{Batch, Rules}

  @impl true
  def mount(_params, _session, socket) do
    summary = Rules.rows("cal_summary", "ORDER BY domain, agent_name")

    buckets =
      Rules.rows("cal_bucket", "ORDER BY bucket")
      |> Enum.group_by(&{&1["agent_id"], &1["domain"]})

    drift = Rules.rows("cal_drift")
    collapse = Rules.rows("cal_collapse_suspected")

    {:ok,
     assign(socket,
       page_title: "Calibration",
       as_of: Batch.as_of(),
       summary: summary,
       buckets: buckets,
       drift: drift,
       collapse: collapse
     )}
  end

  defp f(nil), do: "–"
  defp f(x) when is_float(x), do: :erlang.float_to_binary(x, decimals: 3)
  defp f(x), do: to_string(x)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.header>
        Calibration
        <:subtitle>
          As of {DateTime.to_iso8601(@as_of)}. Final forecasts only. Brier: lower is better. Log score: higher is better (≤ 0).
          Skill: 1 − Brier / uncertainty (0 = always forecast the base rate).
        </:subtitle>
      </.header>

      <section :if={@collapse != []} id="collapse" class="alert alert-warning">
        <div>
          <strong>Predictability collapse suspected</strong>
          in:
          <span :for={c <- @collapse} class="badge">{c["domain"]} (Brier {f(c["baseline_brier"])} → {f(
            c["recent_brier"]
          )})</span>
        </div>
      </section>
      <section :if={@drift != []} id="drift" class="text-sm">
        Drift: <span :for={d <- @drift} class="badge">{d["domain"]} +{f(d["deterioration"])}</span>
      </section>

      <p :if={@summary == []}>No resolved forecasts yet.</p>

      <div
        :for={s <- @summary}
        id={"cal-#{s["agent_id"]}-#{s["domain"]}"}
        class="border border-base-300 rounded p-3 flex flex-wrap gap-6"
      >
        <div>
          <h2 class="font-semibold">
            {s["agent_name"]} <span class="text-sm">({s["agent_kind"]})</span> · {s["domain"]}
          </h2>
          <table class="table table-sm">
            <tr>
              <th>n</th><td>{s["n"]}</td>
            </tr>
            <tr>
              <th>Mean Brier</th><td>{f(s["mean_brier"])}</td>
            </tr>
            <tr>
              <th>Mean log score</th><td>{f(s["mean_log_score"])}</td>
            </tr>
            <tr>
              <th>Skill vs base rate</th><td>{f(s["skill"])}</td>
            </tr>
            <tr>
              <th>Base rate</th><td>{f(s["base_rate"])}</td>
            </tr>
            <tr>
              <th>Reliability</th><td>{f(s["reliability"])}</td>
            </tr>
            <tr>
              <th>Resolution</th><td>{f(s["resolution"])}</td>
            </tr>
            <tr>
              <th>Uncertainty</th><td>{f(s["uncertainty"])}</td>
            </tr>
          </table>
        </div>
        <.reliability buckets={Map.get(@buckets, {s["agent_id"], s["domain"]}, [])} />
      </div>
    </Layouts.app>
    """
  end
end
