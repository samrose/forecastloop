defmodule ForecastLoop.SchemaTest do
  use ForecastLoop.DataCase, async: false

  alias ForecastLoop.Knowledge.Fact

  @app_tables ~w(agents scenarios assumptions question_templates questions model_versions forecasts
                 resolutions scores signals observations regime_shifts knowledge_facts packs
                 work_items runs batch_context config)

  test "every application table has inserted_at, updated_at and asserted_by" do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT table_name, array_agg(column_name::text)
        FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = ANY($1)
        GROUP BY table_name
        """,
        [@app_tables]
      )

    assert length(rows) == length(@app_tables)

    for [table, cols] <- rows, col <- ~w(inserted_at updated_at asserted_by) do
      assert col in cols, "#{table} lacks #{col}"
    end
  end

  test "batch_context has exactly one row and refuses a second" do
    assert Repo.aggregate(ForecastLoop.Batch.Context, :count) == 1

    assert_raise Postgrex.Error, fn ->
      Repo.query!(
        "INSERT INTO batch_context (id, as_of, asserted_by, inserted_at, updated_at) VALUES (false, now(), 't', now(), now())"
      )
    end
  end

  test "with_as_of restores the prior as_of" do
    before = ForecastLoop.Batch.as_of()

    inside =
      ForecastLoop.Batch.with_as_of(ts("2020-01-01T00:00:00Z"), &ForecastLoop.Batch.as_of/0)

    assert inside == ts("2020-01-01T00:00:00Z")
    assert ForecastLoop.Batch.as_of() == before
  end

  describe "knowledge facts" do
    defp fact(attrs) do
      %Fact{}
      |> Fact.changeset(Map.merge(%{subject: "s", object: "o", asserted_by: "test"}, attrs))
      |> Repo.insert()
    end

    test "only the core predicates are accepted" do
      for p <- Fact.predicates(), do: assert({:ok, _} = fact(%{predicate: p, subject: "s-#{p}"}))
      assert {:error, cs} = fact(%{predicate: "made_up"})
      assert cs.errors[:predicate]

      assert_raise Postgrex.Error, ~r/predicate_known/, fn ->
        Repo.query!(
          "INSERT INTO knowledge_facts (predicate, subject, object, asserted_by, inserted_at, updated_at) VALUES ('made_up','s','o','t',now(),now())"
        )
      end
    end

    test "identity includes valid_from, with NULL equal to NULL" do
      assert {:ok, _} = fact(%{predicate: "entity_alias"})
      assert {:error, _} = fact(%{predicate: "entity_alias"})
      assert {:ok, _} = fact(%{predicate: "entity_alias", valid_from: ts("2026-01-01T00:00:00Z")})
    end

    test "valid_to must follow valid_from" do
      assert {:error, cs} =
               fact(%{
                 predicate: "value_alias",
                 valid_from: ts("2026-02-01T00:00:00Z"),
                 valid_to: ts("2026-01-01T00:00:00Z")
               })

      assert cs.errors[:valid_to]
    end
  end

  test "only one open work item per subject and kind" do
    insert = fn status ->
      Repo.query!(
        "INSERT INTO work_items (kind, subject_type, subject_id, status, asserted_by, inserted_at, updated_at) VALUES ('gap','x','1',$1,'t',now(),now())",
        [status]
      )
    end

    insert.("done")
    insert.("open")
    assert_raise Postgrex.Error, ~r/work_items_open_unique/, fn -> insert.("open") end
  end
end
