defmodule ForecastLoopWeb.Charts do
  @moduledoc "Small inline SVG charts: a sparkline with marked regime shifts, and a reliability diagram."
  use Phoenix.Component

  attr :points, :list, required: true, doc: "[{DateTime, value}] in time order"
  attr :shifts, :list, default: [], doc: "[DateTime] of regime shifts"
  attr :width, :integer, default: 240
  attr :height, :integer, default: 48

  def sparkline(assigns) do
    pts = Enum.reject(assigns.points, fn {_t, v} -> is_nil(v) end)
    assigns = assign(assigns, scaled: scale(pts, assigns.shifts, assigns.width, assigns.height))

    ~H"""
    <svg width={@width} height={@height} role="img" aria-label="sparkline" class="text-primary">
      <polyline
        :if={@scaled.line != ""}
        fill="none"
        stroke="currentColor"
        stroke-width="1.5"
        points={@scaled.line}
      />
      <line
        :for={x <- @scaled.shifts}
        x1={x}
        x2={x}
        y1="0"
        y2={@height}
        stroke="red"
        stroke-dasharray="3 2"
      >
        <title>regime shift</title>
      </line>
    </svg>
    """
  end

  defp scale([], _shifts, _w, _h), do: %{line: "", shifts: []}

  defp scale(pts, shifts, w, h) do
    ts = Enum.map(pts, fn {t, _} -> DateTime.to_unix(t) end)
    vs = Enum.map(pts, fn {_, v} -> v end)
    {t0, t1} = {Enum.min(ts), max(Enum.max(ts), Enum.min(ts) + 1)}
    {v0, v1} = {Enum.min(vs), Enum.max(vs)}
    v1 = if v1 == v0, do: v0 + 1, else: v1
    x = fn t -> Float.round(2 + (t - t0) / (t1 - t0) * (w - 4), 1) end
    y = fn v -> Float.round(h - 2 - (v - v0) / (v1 - v0) * (h - 4), 1) end

    %{
      line: Enum.map_join(pts, " ", fn {t, v} -> "#{x.(DateTime.to_unix(t))},#{y.(v)}" end),
      shifts: for(s <- shifts, u = DateTime.to_unix(s), u >= t0 and u <= t1, do: x.(u))
    }
  end

  attr :buckets, :list, required: true, doc: "rows of rules.cal_bucket"
  attr :size, :integer, default: 220

  @doc "Reliability diagram: each decile bin at (mean probability, observed frequency), labelled with its count."
  def reliability(assigns) do
    s = assigns.size
    pad = 24
    span = s - 2 * pad

    bins =
      Enum.map(assigns.buckets, fn b ->
        %{
          x: pad + b["mean_probability"] * span,
          y: s - pad - b["observed_frequency"] * span,
          r: 3 + :math.sqrt(b["n"]) * 2,
          n: b["n"],
          label:
            "decile #{b["bucket"]}: n=#{b["n"]}, mean p=#{Float.round(b["mean_probability"], 2)}, observed=#{Float.round(b["observed_frequency"], 2)}"
        }
      end)

    assigns = assign(assigns, bins: bins, pad: pad, span: span)

    ~H"""
    <svg
      width={@size}
      height={@size}
      role="img"
      aria-label="reliability diagram"
      class="border border-base-300"
    >
      <line
        x1={@pad}
        y1={@size - @pad}
        x2={@size - @pad}
        y2={@pad}
        stroke="gray"
        stroke-dasharray="4 3"
      />
      <line x1={@pad} y1={@size - @pad} x2={@size - @pad} y2={@size - @pad} stroke="currentColor" />
      <line x1={@pad} y1={@size - @pad} x2={@pad} y2={@pad} stroke="currentColor" />
      <text x={@size / 2} y={@size - 4} font-size="10" text-anchor="middle">
        forecast probability
      </text>
      <text
        x="10"
        y={@size / 2}
        font-size="10"
        text-anchor="middle"
        transform={"rotate(-90 10 #{@size / 2})"}
      >
        observed frequency
      </text>
      <g :for={b <- @bins}>
        <circle cx={b.x} cy={b.y} r={b.r} fill="steelblue" fill-opacity="0.6">
          <title>{b.label}</title>
        </circle>
        <text x={b.x + b.r + 2} y={b.y + 3} font-size="9">{b.n}</text>
      </g>
    </svg>
    """
  end
end
