defmodule ForecastLoop.Fixtures do
  @moduledoc "Test data builders. Each inserts one row and returns it."
  alias ForecastLoop.{Ledger, Observations, Repo}
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
end
