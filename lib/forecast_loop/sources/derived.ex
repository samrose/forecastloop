defmodule ForecastLoop.Sources.Derived do
  @moduledoc """
  Computes a derived series from other signals' as-of observations. A derived
  spec is declarative (docs/adr/0009): it names one core operation, and one SQL
  function in the `derive` schema computes it at `batch_context.as_of`.

  Operations:

    * `aggregate_by_period` — `%{"signal" => name, "period" => "weekly" | "monthly" | "quarterly",
      "agg" => "count" | "sum" | "mean", "where" => %{attr => value | [values]},
      "group_by" => attr | nil}`
    * `change_over_periods` — `%{"signal" => name, "lag" => n, "mode" => "difference" | "percent"}`
    * `ratio` — `%{"numerator" => name, "denominator" => name}`

  Signals are named, not numbered, so a pack's specs work in any database.
  """
  @behaviour ForecastLoop.Sources

  alias ForecastLoop.{Batch, Repo, Signals}

  @impl true
  def describe,
    do:
      "Derived series from other signals (operations: aggregate_by_period, change_over_periods, ratio)."

  @impl true
  def fetch(spec, _since), do: compute(spec, Batch.as_of())

  @impl true
  def preview(spec) do
    with {:ok, rows} <- compute(spec, Batch.as_of()), do: {:ok, Enum.take(rows, 20)}
  end

  @doc "Names of the signals that a derived spec reads."
  @spec inputs(map()) :: [String.t()]
  def inputs(%{"operation" => "ratio"} = spec), do: [spec["numerator"], spec["denominator"]]
  def inputs(%{"signal" => name}), do: [name]
  def inputs(_spec), do: []

  @doc "Computes the derived rows as of `t`."
  @spec compute(map(), DateTime.t()) :: {:ok, [ForecastLoop.Sources.row()]} | {:error, term()}
  def compute(%{"operation" => op} = spec, t) do
    with {:ok, ids} <- resolve(inputs(spec)),
         {:ok, sql, params} <- call(op, spec, ids, t),
         {:ok, %{rows: rows}} <- Repo.query(sql, params) do
      {:ok, Enum.map(rows, &to_row/1)}
    else
      {:error, %Postgrex.Error{} = e} -> {:error, {:query, Exception.message(e)}}
      error -> error
    end
  end

  def compute(_spec, _t), do: {:error, :spec_has_no_operation}

  @periods ~w(weekly monthly quarterly)
  @aggs ~w(count sum mean)

  defp call("aggregate_by_period", spec, [id], t) do
    cond do
      spec["period"] not in @periods ->
        {:error, {:bad_period, spec["period"]}}

      spec["agg"] not in @aggs ->
        {:error, {:bad_agg, spec["agg"]}}

      not is_map(Map.get(spec, "where", %{})) ->
        {:error, :bad_where}

      true ->
        {:ok, "SELECT * FROM derive.aggregate_by_period($1, $2, $3, $4, $5, $6)",
         [id, spec["period"], spec["agg"], Map.get(spec, "where", %{}), spec["group_by"], t]}
    end
  end

  defp call("change_over_periods", spec, [id], t) do
    lag = Map.get(spec, "lag", 1)
    mode = Map.get(spec, "mode", "difference")

    if is_integer(lag) and lag > 0 and mode in ~w(difference percent),
      do: {:ok, "SELECT * FROM derive.change_over_periods($1, $2, $3, $4)", [id, lag, mode, t]},
      else: {:error, {:bad_change_spec, lag, mode}}
  end

  defp call("ratio", _spec, [num, den], t),
    do: {:ok, "SELECT * FROM derive.ratio($1, $2, $3)", [num, den, t]}

  defp call(op, _spec, _ids, _t), do: {:error, {:unknown_operation, op}}

  defp resolve(names) do
    Enum.reduce_while(names, {:ok, []}, fn name, {:ok, acc} ->
      case Signals.get_by_name(name) do
        nil -> {:halt, {:error, {:unknown_input_signal, name}}}
        s -> {:cont, {:ok, acc ++ [s.id]}}
      end
    end)
  end

  defp to_row([id, eff, obs, value, attrs]),
    do: %{
      source_record_id: id,
      effective_at: eff,
      observed_at: obs,
      value: value,
      attributes: attrs
    }
end
