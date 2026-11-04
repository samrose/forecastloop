defmodule ForecastLoop.Knowledge do
  @moduledoc """
  Knowledge facts: the hand-asserted facts that the `k_*` rule views apply to raw
  observations. Domain meaning enters the core only here, through the predicates
  in `ForecastLoop.Knowledge.Fact.predicates/0`.
  """
  import Ecto.Query
  alias ForecastLoop.Knowledge.Fact
  alias ForecastLoop.Repo
  alias ForecastLoop.Sources.{CSV, Mapping}

  @csv_columns ~w(predicate subject object attributes valid_from valid_to domain pack note asserted_by)

  @doc "Asserts one fact. A fact with the same (predicate, subject, object, valid_from) is updated."
  @spec assert_fact(map()) :: {:ok, Fact.t()} | {:error, Ecto.Changeset.t()}
  def assert_fact(attrs) do
    cs = Fact.changeset(%Fact{}, attrs)

    if cs.valid? do
      upsert(Ecto.Changeset.apply_changes(cs))
    else
      {:error, cs}
    end
  end

  def update_fact(%Fact{} = fact, attrs), do: fact |> Fact.changeset(attrs) |> Repo.update()
  def delete_fact(%Fact{} = fact), do: Repo.delete(fact)
  def get_fact!(id), do: Repo.get!(Fact, id)

  @doc "Lists facts. Options: `:predicate`, `:domain`, `:pack`, `:subject`."
  def list_facts(opts \\ []) do
    Enum.reduce(
      opts,
      from(f in Fact, order_by: [f.predicate, f.subject, f.object, f.valid_from]),
      fn
        {k, v}, q when k in [:predicate, :domain, :pack, :subject] and not is_nil(v) ->
          where(q, [f], field(f, ^k) == ^v)

        _, q ->
          q
      end
    )
    |> Repo.all()
  end

  # Insert, or update the existing fact with the same identity. The update runs only
  # when a field differs, so re-importing the same facts changes nothing.
  defp upsert(%Fact{} = f) do
    now = DateTime.utc_now()

    %{rows: [row], columns: cols} =
      Repo.query!(
        """
        INSERT INTO knowledge_facts AS k
          (predicate, subject, object, attributes, valid_from, valid_to, domain, pack, note,
           asserted_by, inserted_at, updated_at)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $11)
        ON CONFLICT (predicate, subject, object, valid_from) DO UPDATE SET
          attributes = EXCLUDED.attributes, valid_to = EXCLUDED.valid_to, domain = EXCLUDED.domain,
          pack = EXCLUDED.pack, note = EXCLUDED.note, asserted_by = EXCLUDED.asserted_by,
          updated_at = EXCLUDED.updated_at
        WHERE (k.attributes, k.valid_to, k.domain, k.pack, k.note)
              IS DISTINCT FROM (EXCLUDED.attributes, EXCLUDED.valid_to, EXCLUDED.domain, EXCLUDED.pack, EXCLUDED.note)
        RETURNING *
        """,
        [
          f.predicate,
          f.subject,
          f.object,
          f.attributes || %{},
          f.valid_from,
          f.valid_to,
          f.domain,
          f.pack,
          f.note,
          f.asserted_by,
          now
        ]
      )
      |> case do
        %{rows: []} ->
          Repo.query!(
            "SELECT * FROM knowledge_facts WHERE predicate = $1 AND subject = $2 AND object = $3 AND valid_from IS NOT DISTINCT FROM $4",
            [f.predicate, f.subject, f.object, f.valid_from]
          )

        result ->
          result
      end

    {:ok, Repo.load(Fact, {cols, row})}
  rescue
    e in Postgrex.Error ->
      {:error,
       f |> Fact.changeset(%{}) |> Ecto.Changeset.add_error(:predicate, Exception.message(e))}
  end

  @doc """
  Imports facts from a CSV file with a header row. Columns: #{Enum.join(@csv_columns, ", ")}.
  Only `predicate`, `subject` and `object` are required. `attributes` is JSON.
  `valid_from` and `valid_to` are ISO 8601 dates or timestamps. Idempotent.
  Returns `{:ok, count}` or `{:error, {line, reason}}`; on error nothing is imported.
  Options: `:pack` and `:asserted_by` fill columns that the file leaves empty.
  """
  @spec import_csv(Path.t(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def import_csv(path, opts \\ []) do
    with {:ok, body} <- File.read(path),
         {:ok, _cols, records} <- CSV.parse(body) do
      Repo.transact(fn -> import_records(records, path, opts) end)
    end
  end

  # Line numbers start at 2 because line 1 is the header.
  defp import_records(records, path, opts) do
    records
    |> Enum.with_index(2)
    |> Enum.reduce_while({:ok, 0}, fn {rec, line}, {:ok, n} ->
      case rec |> csv_attrs(path, opts) |> assert_csv_fact() do
        {:ok, _} -> {:cont, {:ok, n + 1}}
        {:error, reason} -> {:halt, {:error, {line, reason}}}
      end
    end)
  end

  defp assert_csv_fact({:error, _} = e), do: e

  defp assert_csv_fact({:ok, attrs}) do
    case assert_fact(attrs) do
      {:ok, f} -> {:ok, f}
      {:error, cs} -> {:error, errors(cs)}
    end
  end

  defp csv_attrs(rec, path, opts) do
    blank = &blank(rec, &1)

    with {:ok, attributes} <- json(blank.("attributes")),
         {:ok, vf} <- time(blank.("valid_from")),
         {:ok, vt} <- time(blank.("valid_to")) do
      {:ok,
       %{
         predicate: blank.("predicate"),
         subject: blank.("subject"),
         object: blank.("object"),
         attributes: attributes,
         valid_from: vf,
         valid_to: vt,
         domain: blank.("domain"),
         pack: blank.("pack") || opts[:pack],
         note: blank.("note"),
         asserted_by:
           blank.("asserted_by") || opts[:asserted_by] || "import:" <> Path.basename(path)
       }}
    end
  end

  # The trimmed value of a CSV column, or nil when it is missing or empty.
  defp blank(rec, key) do
    case rec |> Map.get(key, "") |> String.trim() do
      "" -> nil
      v -> v
    end
  end

  defp json(nil), do: {:ok, %{}}

  defp json(s) do
    case Jason.decode(s) do
      {:ok, m} when is_map(m) -> {:ok, m}
      _ -> {:error, {:attributes_not_a_json_object, s}}
    end
  end

  defp time(nil), do: {:ok, nil}
  defp time(s), do: Mapping.parse_time(s, "iso8601")

  defp errors(cs) do
    Ecto.Changeset.traverse_errors(cs, fn {msg, _} -> msg end)
  end
end
