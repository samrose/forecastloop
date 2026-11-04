defmodule ForecastLoop.Batch.Snapshot do
  @moduledoc """
  Batch step "Knowledge snapshot": writes every `rules.k_*` view to
  `<runs_dir>/<run_id>/<view>.csv`, so a run's classification can be reproduced
  after the knowledge facts change. `runs_dir` comes from
  `config :forecast_loop, :runs_dir` (default `priv/runs`).
  """
  alias ForecastLoop.{Repo, Rules}

  @spec dir(integer()) :: Path.t()
  def dir(run_id),
    do: Path.join(Application.get_env(:forecast_loop, :runs_dir, "priv/runs"), to_string(run_id))

  @spec write(integer()) :: %{String.t() => non_neg_integer()}
  def write(run_id) do
    dir = dir(run_id)
    File.mkdir_p!(dir)

    Map.new(Rules.views("k"), fn view ->
      %{columns: cols, rows: rows} = Repo.query!(~s(SELECT * FROM rules."#{view}" ORDER BY 1, 2))

      csv =
        NimbleCSV.RFC4180.dump_to_iodata([
          cols | Enum.map(rows, fn r -> Enum.map(r, &cell/1) end)
        ])

      File.write!(Path.join(dir, view <> ".csv"), csv)
      {view, length(rows)}
    end)
  end

  defp cell(nil), do: ""
  defp cell(%DateTime{} = d), do: DateTime.to_iso8601(d)
  defp cell(v) when is_map(v) or is_list(v), do: Jason.encode!(v)
  defp cell(v), do: to_string(v)
end
