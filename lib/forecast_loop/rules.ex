defmodule ForecastLoop.Rules do
  @moduledoc """
  Read access to the rule layer: the views in the `rules` schema. Elixir code reads
  these views and acts on their rows; the views decide.

  View groups (by name prefix): `k_` knowledge, `gap_` gaps, `loop_` forecasting
  cycle, `cal_` scoring and calibration.
  """
  alias ForecastLoop.Repo

  @groups ~w(k gap loop cal)

  @doc "Names of the views in the `rules` schema, optionally only one group."
  @spec views(String.t() | nil) :: [String.t()]
  def views(group \\ nil) when is_nil(group) or group in @groups do
    %{rows: rows} =
      Repo.query!("SELECT viewname FROM pg_views WHERE schemaname = 'rules' ORDER BY viewname")

    names = List.flatten(rows)
    if group, do: Enum.filter(names, &String.starts_with?(&1, group <> "_")), else: names
  end

  @doc "Each view with its `COMMENT ON VIEW` text."
  @spec catalog() :: [%{name: String.t(), comment: String.t() | nil}]
  def catalog do
    %{rows: rows} =
      Repo.query!("""
      SELECT c.relname, obj_description(c.oid, 'pg_class')
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = 'rules' AND c.relkind IN ('v', 'm')
      ORDER BY c.relname
      """)

    Enum.map(rows, fn [name, comment] -> %{name: name, comment: comment} end)
  end

  @doc "All rows of a rules view, as maps with string keys."
  @spec rows(String.t(), String.t()) :: [map()]
  def rows(view, suffix \\ "") do
    unless view in views(), do: raise(ArgumentError, "unknown rules view #{inspect(view)}")
    %{columns: cols, rows: rows} = Repo.query!(~s(SELECT * FROM rules."#{view}" #{suffix}))
    Enum.map(rows, &(cols |> Enum.zip(&1) |> Map.new()))
  end

  @doc """
  Runs a read-only query against the `rules` schema (for the MCP `query` tool and
  the UI). The query runs in a read-only transaction that is always rolled back,
  with a statement timeout, `search_path = rules`, and the role
  `forecast_loop_rules_reader`, which can read the rule views only (and the
  `observations` and `batch_context` tables that the views' functions read).
  Returns `{:ok, %{columns, rows, sql}}` or `{:error, message}`.
  """
  @spec query(String.t(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def query(sql, opts \\ []) do
    timeout = Keyword.get(opts, :timeout_ms, 5_000)
    limit = Keyword.get(opts, :limit, 500)

    Repo.transaction(fn ->
      Repo.query!("SET TRANSACTION READ ONLY")
      Repo.query!("SET LOCAL statement_timeout = #{timeout}")
      Repo.query!("SET LOCAL search_path = rules, fl, public")
      Repo.query!("SET LOCAL ROLE forecast_loop_rules_reader")

      case Repo.query(sql) do
        {:ok, %{columns: cols, rows: rows}} ->
          Repo.rollback(
            {:ok, %{columns: cols || [], rows: Enum.take(rows || [], limit), sql: sql}}
          )

        {:error, e} ->
          Repo.rollback({:error, Exception.message(e)})
      end
    end)
    |> case do
      {:error, result} -> result
    end
  end
end
