defmodule ForecastLoop.Fixtures do
  @moduledoc "Test data builders. Each inserts one row and returns it."
  alias ForecastLoop.{Ledger, Observations, Repo}
  alias ForecastLoop.Ledger.Question
  alias ForecastLoop.Signals.Signal

  def ts(iso) do
    {:ok, dt, 0} = DateTime.from_iso8601(iso)
    DateTime.add(dt, 0, :microsecond)
  end

  def agent(name \\ "agent-#{System.unique_integer([:positive])}", kind \\ "human") do
    {:ok, a} = Ledger.create_agent(%{name: name, kind: kind, asserted_by: "test"})
    a
  end

  def signal(attrs \\ %{}) do
    attrs =
      Map.merge(
        %{
          name: "signal-#{System.unique_integer([:positive])}",
          domain: "test_domain",
          kind: "series",
          source_spec: %{"system" => "csv"},
          asserted_by: "test"
        },
        attrs
      )

    %Signal{} |> Signal.changeset(attrs) |> Repo.insert!()
  end

  def observe(signal, record_id, effective_at, observed_at, value, attributes \\ %{}) do
    1 =
      Observations.append(
        [
          %{
            signal_id: signal.id,
            source_record_id: record_id,
            effective_at: ts(effective_at),
            observed_at: ts(observed_at),
            value: value,
            attributes: attributes
          }
        ],
        "test"
      )

    :ok
  end

  def fip_attrs(author, overrides \\ %{}) do
    Map.merge(
      %{
        title: "Test question",
        event_definition: "The test event happens.",
        resolution_condition: %{"type" => "manual"},
        deadline: ts("2027-01-01T00:00:00Z"),
        domain: "test_domain",
        created_by_id: author.id,
        asserted_by: "test"
      },
      overrides
    )
  end

  def question(author, overrides \\ %{}) do
    {:ok, q} = Ledger.create_question(fip_attrs(author, overrides))
    q
  end

  @doc "A live question: created by `author`, reviewed by another agent, promoted."
  def live_question(author, overrides \\ %{}) do
    q = question(author, overrides)
    {:ok, q} = Ledger.review_question(q, agent(), "test")

    q
    |> Question.changeset(%{status: "live", asserted_by: "test"})
    |> Repo.update!()
  end

  def forecast(q, agent, p, made_at, extra \\ %{}) do
    {:ok, f} =
      Ledger.submit_forecast(
        Map.merge(
          %{
            question_id: q.id,
            agent_id: agent.id,
            probability: p,
            made_at: ts(made_at),
            asserted_by: "test"
          },
          extra
        )
      )

    f
  end

  def resolve(q, outcome, at) do
    {:ok, r} =
      Ledger.resolve_question(q, %{
        outcome: outcome,
        resolved_at: ts(at),
        source: "test",
        resolved_by: "test",
        asserted_by: "test"
      })

    r
  end

  @doc "A series condition on `signal` with an explicit window."
  def series_rc(signal, op, value, from, to, at \\ "end_of_window") do
    %{
      "type" => "series",
      "signal_id" => signal.id,
      "op" => op,
      "value" => value,
      "at" => at,
      "window" => %{"from" => from, "to" => to}
    }
  end

  def events_rc(signal, op, value, from, to, where \\ %{}) do
    %{
      "type" => "events",
      "signal_id" => signal.id,
      "op" => op,
      "value" => value,
      "where" => where,
      "window" => %{"from" => from, "to" => to}
    }
  end

  def set_config(key, value) do
    Repo.query!(
      "INSERT INTO config (key, value, asserted_by, inserted_at, updated_at) VALUES ($1, $2, 'test', now(), now()) ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value",
      [key, value]
    )
  end
end
