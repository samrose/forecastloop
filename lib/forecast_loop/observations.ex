defmodule ForecastLoop.Observations do
  @moduledoc """
  As-of access to observations.

  `as_of/2` is the only read path for data that feeds models, rules or backtests.
  It calls the SQL function `observations_as_of(t)`, the single definition of the
  as-of query. The rule views call the same function with `batch_context.as_of`.
  """
  alias ForecastLoop.Repo
  alias ForecastLoop.Signals.Observation

  @doc """
  Returns, for each (signal, source record), the vintage with the latest
  `observed_at <= t`, ordered by signal and `effective_at`.
  """
  @spec as_of([integer()], DateTime.t()) :: [Observation.t()]
  def as_of(signal_ids, %DateTime{} = t) when is_list(signal_ids) do
    %{columns: cols, rows: rows} =
      Repo.query!(
        """
        SELECT * FROM observations_as_of($1)
        WHERE signal_id = ANY($2)
        ORDER BY signal_id, effective_at, source_record_id
        """,
        [t, signal_ids]
      )

    Enum.map(rows, &Repo.load(Observation, {cols, &1}))
  end

  @doc """
  Appends observation rows. A row that already exists with the same
  (signal_id, source_record_id, observed_at) is skipped. Returns the count inserted.
  """
  @spec append([map()], String.t()) :: non_neg_integer()
  def append([], _asserted_by), do: 0

  def append(rows, asserted_by) do
    now = DateTime.utc_now()

    entries =
      Enum.map(rows, fn r ->
        %{
          signal_id: r.signal_id,
          effective_at: r.effective_at,
          observed_at: r.observed_at,
          value: r[:value] && r.value * 1.0,
          attributes: r[:attributes] || %{},
          source_record_id: to_string(r.source_record_id),
          asserted_by: asserted_by,
          inserted_at: now,
          updated_at: now
        }
      end)

    entries
    |> Enum.chunk_every(1000)
    |> Enum.reduce(0, fn chunk, acc ->
      {n, _} =
        Repo.insert_all(Observation, chunk,
          on_conflict: :nothing,
          conflict_target: [:signal_id, :source_record_id, :observed_at]
        )

      acc + n
    end)
  end
end
