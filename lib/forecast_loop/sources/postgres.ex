defmodule ForecastLoop.Sources.Postgres do
  @moduledoc """
  Runs a SQL query against a PostgreSQL warehouse, in a read-only transaction with
  a statement timeout.

  Spec: `%{"system" => "postgres", "connection" => name, "query" => sql, "fields" => ...}`.
  `connection` is `"repo"` (this application's database) or a key of
  `config :forecast_loop, :warehouses` (Postgrex connection options). If the
  query contains `$1`, it is bound to the latest stored `observed_at` (or
  `-infinity`), so the query can return only new rows.
  """
  @behaviour ForecastLoop.Sources

  alias ForecastLoop.Repo
  alias ForecastLoop.Sources.Mapping

  @timeout_ms 60_000

  @impl true
  def describe,
    do: "SQL query against a PostgreSQL warehouse (spec keys: connection, query, fields)."

  @impl true
  def fetch(spec, since) do
    with {:ok, columns, records} <- run(spec, since),
         :ok <- Mapping.check_columns(columns, spec) do
      Mapping.to_rows(records, spec, DateTime.utc_now(), since)
    end
  end

  @impl true
  def preview(spec) do
    with {:ok, rows} <- fetch(spec, nil), do: {:ok, Enum.take(rows, 20)}
  end

  defp run(%{"query" => sql} = spec, since) do
    params = if String.contains?(sql, "$1"), do: [since || :"-infinity"], else: []
    params = Enum.map(params, &bind/1)

    case Map.get(spec, "connection", "repo") do
      "repo" -> in_read_only(&Repo.query(&1, &2), sql, params, Repo)
      name -> with_warehouse(name, sql, params)
    end
  end

  defp run(_spec, _since), do: {:error, :spec_has_no_query}

  defp bind(:"-infinity"), do: ~U[0001-01-01 00:00:00.000000Z]
  defp bind(dt), do: dt

  defp with_warehouse(name, sql, params) do
    case Map.fetch(Application.get_env(:forecast_loop, :warehouses, %{}), name) do
      {:ok, opts} ->
        {:ok, conn} = Postgrex.start_link(opts)

        try do
          in_read_only(&Postgrex.query(conn, &1, &2), sql, params, conn)
        after
          GenServer.stop(conn)
        end

      :error ->
        {:error, {:unknown_connection, name}}
    end
  end

  # Runs `sql` in a read-only transaction with a statement timeout, then always
  # rolls back. The rollback also undoes the SET LOCAL settings, so they do not
  # leak into an enclosing transaction (for example the test sandbox).
  # `query` is a 2-arity function that runs one statement on the connection.
  defp in_read_only(query, sql, params, Repo) do
    Repo.transaction(fn -> Repo.rollback(read_only_query(query, sql, params)) end)
    |> rolled_back()
  end

  defp in_read_only(query, sql, params, conn) do
    Postgrex.transaction(conn, fn conn ->
      Postgrex.rollback(conn, read_only_query(query, sql, params))
    end)
    |> rolled_back()
  end

  defp rolled_back({:error, {:ok, {cols, recs}}}), do: {:ok, cols, recs}
  defp rolled_back({:error, {:error, e}}), do: {:error, error(e)}
  defp rolled_back({:error, e}), do: {:error, error(e)}

  defp read_only_query(query, sql, params) do
    with {:ok, _} <- query.("SET TRANSACTION READ ONLY", []),
         {:ok, _} <- query.("SET LOCAL statement_timeout = #{@timeout_ms}", []) do
      query.(sql, params) |> to_records()
    end
  end

  defp to_records({:ok, %{columns: cols, rows: rows}}),
    do: {:ok, {cols, Enum.map(rows, &(cols |> Enum.zip(&1) |> Map.new()))}}

  defp to_records({:error, e}), do: {:error, error(e)}

  defp error(%Postgrex.Error{} = e), do: {:query, Exception.message(e)}
  defp error(e), do: e
end
