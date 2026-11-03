defmodule ForecastLoop.LedgerTest do
  use ForecastLoop.DataCase, async: true

  alias ForecastLoop.Ledger
  alias ForecastLoop.Ledger.Question

  describe "Forecast Integrity Protocol" do
    test "create_question refuses a question without each FIP field" do
      author = agent()

      for field <- Question.fip_fields() do
        assert {:error, cs} = Ledger.create_question(fip_attrs(author, %{field => nil}))
        assert {"is a required Forecast Integrity Protocol field", _} = cs.errors[field]
      end
    end

    test "a draft may lack FIP fields" do
      assert {:ok, %{status: "draft"}} =
               Ledger.create_draft_question(%{
                 title: "Rough idea",
                 created_by_id: agent().id,
                 asserted_by: "test"
               })
    end

    test "resolution condition shapes are validated" do
      author = agent()

      good_series = %{
        "type" => "series",
        "signal_id" => 1,
        "op" => ">=",
        "value" => 4.5,
        "at" => "end_of_window"
      }

      good_events = %{
        "type" => "events",
        "signal_id" => 1,
        "op" => "count>=",
        "value" => 1,
        "where" => %{"class" => "x"}
      }

      assert :ok = Question.validate_resolution_condition(good_series)
      assert :ok = Question.validate_resolution_condition(good_events)

      assert {:error, _} =
               Question.validate_resolution_condition(%{good_series | "op" => "count>="})

      assert {:error, _} =
               Question.validate_resolution_condition(%{good_series | "at" => "sometime"})

      assert {:error, _} = Question.validate_resolution_condition(%{"type" => "vibes"})

      assert {:error, _} =
               Ledger.create_question(
                 fip_attrs(author, %{resolution_condition: %{"type" => "vibes"}})
               )
    end

    test "the database rejects a bad resolution condition that skips the changeset" do
      q = question(agent())

      assert_raise Postgrex.Error, ~r/resolution_condition_shape/, fn ->
        Repo.update_all(from(x in Question, where: x.id == ^q.id),
          set: [resolution_condition: %{"type" => "series", "signal_id" => 1}]
        )
      end
    end
  end

  describe "going live" do
    test "a question cannot go live without a reviewer" do
      q = question(agent())

      assert {:error, cs} =
               q |> Question.changeset(%{status: "live", asserted_by: "test"}) |> Repo.update()

      assert cs.errors[:status]
    end

    test "a question cannot go live when its author reviewed it" do
      author = agent()
      q = question(author)
      {:ok, q} = Ledger.review_question(q, author, "test")

      assert {:error, cs} =
               q |> Question.changeset(%{status: "live", asserted_by: "test"}) |> Repo.update()

      assert {"FIP fields and an independent reviewer are required", _} = cs.errors[:status]
    end

    test "the constraint holds even for raw SQL" do
      author = agent()
      q = question(author)

      assert_raise Postgrex.Error, ~r/fip_before_live/, fn ->
        Repo.update_all(from(x in Question, where: x.id == ^q.id),
          set: [status: "live", reviewed_by_id: author.id]
        )
      end
    end

    test "a question reviewed by a different agent can go live" do
      q = question(agent())
      {:ok, q} = Ledger.review_question(q, agent(), "test")

      assert {:ok, %{status: "live"}} =
               q |> Question.changeset(%{status: "live", asserted_by: "test"}) |> Repo.update()
    end
  end

  test "resolving a question records the outcome and marks it resolved" do
    q = question(agent())
    {:ok, q} = Ledger.review_question(q, agent(), "test")
    {:ok, q} = q |> Question.changeset(%{status: "live", asserted_by: "test"}) |> Repo.update()

    {:ok, res} =
      Ledger.resolve_question(q, %{
        outcome: true,
        resolved_at: ts("2026-12-01T00:00:00Z"),
        source: "manual",
        resolved_by: "test",
        asserted_by: "test"
      })

    assert res.outcome
    assert Ledger.get_question!(q.id).status == "resolved"
  end
end
