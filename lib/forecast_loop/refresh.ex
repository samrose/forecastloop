defmodule ForecastLoop.Refresh do
  @moduledoc """
  Batch steps "Refresh" and "Derive": run each signal's spec through its source
  and append the rows that are new or changed.

  ## Vintages

  Observations are append-only. A row is appended only when it is new or its
  content (`effective_at`, `value`, `attributes`) differs from the latest stored
  vintage of the same record. So a refresh of unchanged data appends nothing,
  and a revised value becomes a new vintage with a later `observed_at`. Rows with
  an `observed_at` at or before the latest stored vintage of their record are
  history that we already hold, and are skipped. See docs/adr/0010.

  ## Failure

  A signal's rows are validated before any insert and are inserted in one
  transaction. A fetch error opens a `refresh_failed` work item; a shape change
  opens a `definition_change` work item. Either way, nothing is ingested for that
  signal. The next successful refresh of the signal closes those work items.
  """
  alias ForecastLoop.{Batch, Observations, Repo, Signals, Sources}
  alias ForecastLoop.Signals.Signal
  alias ForecastLoop.Sources.Derived

  @end_of_time ~U[9999-12-31 00:00:00.000000Z]

  @doc "Refreshes every non-derived signal. Returns step stats."
  @spec refresh_all(keyword()) :: map()
  def refresh_all(opts \\ []) do
    Signals.list_signals()
    |> Enum.reject(&(&1.kind == "derived"))
    |> run_each(opts)
  end

  @doc "Computes every derived signal, inputs before the signals that read them. Returns step stats."
  @spec derive_all(keyword()) :: map()
  def derive_all(opts \\ []) do
    Signals.list_signals(kind: "derived")
    |> dependency_order()
    |> run_each(opts)
  end

  defp run_each(signals, opts) do
    Enum.reduce(
      signals,
      %{"signals" => 0, "appended" => 0, "failed" => 0, "definition_changes" => 0},
      fn s, acc ->
        acc = Map.update!(acc, "signals", &(&1 + 1))

        case refresh_signal(s, opts) do
          {:ok, n} -> Map.update!(acc, "appended", &(&1 + n))
          {:error, :definition_change, _} -> Map.update!(acc, "definition_changes", &(&1 + 1))
          {:error, :refresh_failed, _} -> Map.update!(acc, "failed", &(&1 + 1))
        end
      end
    )
  end

  @doc """
  Refreshes one signal. Returns `{:ok, appended_count}` or
  `{:error, :refresh_failed | :definition_change, reason}`.
  Options: `:run_id`.
  """
  @spec refresh_signal(Signal.t(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, :refresh_failed | :definition_change, term()}
  def refresh_signal(%Signal{} = signal, opts \\ []) do
    run_id = Keyword.get(opts, :run_id)
    latest = latest_by_record(signal)

    with {:ok, mod} <- Sources.module_for(signal.source_spec),
         {:ok, rows} <- safe_fetch(mod, signal.source_spec, since(latest)),
         {:ok, n} <- ingest(signal, rows, latest) do
      close_failures(signal)
      {:ok, n}
    else
      {:error, {:shape_changed, details}} ->
        open(signal, "definition_change", %{"details" => inspect_json(details)}, run_id)
        {:error, :definition_change, details}

      {:error, reason} ->
        open(signal, "refresh_failed", %{"reason" => inspect(reason)}, run_id)
        {:error, :refresh_failed, reason}
    end
  end

  defp safe_fetch(mod, spec, since) do
    mod.fetch(spec, since)
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  end

  # Latest stored vintage of each record, read through the single as-of function.
  defp latest_by_record(signal) do
    [signal.id] |> Observations.as_of(@end_of_time) |> Map.new(&{&1.source_record_id, &1})
  end

  defp since(latest) when map_size(latest) == 0, do: nil

  defp since(latest),
    do: latest |> Map.values() |> Enum.map(& &1.observed_at) |> Enum.max(DateTime)

  @doc false
  def ingest(signal, rows, latest) do
    new_rows =
      rows
      |> Enum.sort_by(&{&1.source_record_id, DateTime.to_unix(&1.observed_at, :microsecond)})
      |> Enum.chunk_by(& &1.source_record_id)
      |> Enum.flat_map(&changed_vintages(&1, Map.get(latest, hd(&1).source_record_id)))
      |> Enum.map(&Map.put(&1, :signal_id, signal.id))

    Repo.transact(fn ->
      n = Observations.append(new_rows, "refresh:#{signal.source_spec["system"]}")
      update_coverage(signal, new_rows)
      {:ok, n}
    end)
  end

  # Walks one record's fetched vintages in observed_at order and keeps each one
  # that is later than what we hold and differs from the one before it.
  defp changed_vintages(vintages, stored) do
    {kept, _prev} =
      Enum.reduce(vintages, {[], stored}, fn row, {kept, prev} ->
        cond do
          prev && DateTime.compare(row.observed_at, prev.observed_at) != :gt -> {kept, prev}
          prev && same_content?(row, prev) -> {kept, prev}
          true -> {[row | kept], row}
        end
      end)

    Enum.reverse(kept)
  end

  defp same_content?(a, b) do
    DateTime.compare(a.effective_at, b.effective_at) == :eq and a.value == b.value and
      normalize(a.attributes) == normalize(b.attributes)
  end

  # Attributes go through JSON in the database, so compare them as JSON would see them.
  defp normalize(attrs), do: attrs |> Jason.encode!() |> Jason.decode!()

  defp update_coverage(_signal, []), do: :ok

  defp update_coverage(signal, rows) do
    times = Enum.map(rows, & &1.effective_at)
    lo = Enum.min([signal.coverage_start | times] |> Enum.reject(&is_nil/1), DateTime)
    hi = Enum.max([signal.coverage_end | times] |> Enum.reject(&is_nil/1), DateTime)

    if lo != signal.coverage_start or hi != signal.coverage_end do
      signal
      |> Ecto.Changeset.change(coverage_start: lo, coverage_end: hi)
      |> Repo.update!()
    end

    :ok
  end

  defp open(signal, kind, payload, run_id) do
    Batch.open_work_item(
      kind,
      "signal",
      signal.id,
      Map.put(payload, "signal", signal.name),
      run_id
    )
  end

  defp close_failures(signal) do
    Batch.close_work_items(["refresh_failed", "definition_change"], "signal", signal.id)
  end

  defp inspect_json(details) when is_map(details),
    do: Map.new(details, fn {k, v} -> {to_string(k), v} end)

  defp inspect_json(details), do: inspect(details)

  @doc false
  # Orders derived signals so that each one comes after the derived signals it reads.
  def dependency_order(signals) do
    by_name = Map.new(signals, &{&1.name, &1})

    {ordered, _seen} =
      Enum.reduce(signals, {[], MapSet.new()}, fn s, acc ->
        visit(s, by_name, acc, MapSet.new())
      end)

    Enum.reverse(ordered)
  end

  defp visit(s, by_name, {ordered, seen}, path) do
    if MapSet.member?(seen, s.name) or MapSet.member?(path, s.name) do
      {ordered, seen}
    else
      path = MapSet.put(path, s.name)

      {ordered, seen} =
        s.source_spec
        |> Derived.inputs()
        |> Enum.flat_map(&List.wrap(Map.get(by_name, &1)))
        |> Enum.reduce({ordered, seen}, &visit(&1, by_name, &2, path))

      {[s | ordered], MapSet.put(seen, s.name)}
    end
  end
end
