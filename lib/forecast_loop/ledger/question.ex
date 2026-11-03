defmodule ForecastLoop.Ledger.Question do
  @moduledoc """
  A forecasting question.

  The four Forecast Integrity Protocol (FIP) fields are `event_definition`,
  `resolution_condition`, `deadline` and `domain` (see docs/adr/0006). A draft
  can lack them. `fip_changeset/2` requires all four; the database rejects a
  `live` or `resolved` question without them or without a reviewer who is not
  the author.

  `resolution_condition` is one of:

    * `%{"type" => "manual"}`
    * `%{"type" => "series", "signal_id" => id, "op" => ">=" | "<=" | ">" | "<",
         "value" => x, "at" => "end_of_window" | "any_in_window" | "mean_in_window",
         "window" => %{"from" => iso8601, "to" => iso8601}}`
    * `%{"type" => "events", "signal_id" => id, "op" => "count>=" | "count<=",
         "value" => n, "window" => %{...}, "where" => %{attr => value | [values]}}`.
      In `where`, the key `"class"` matches a class from `rules.k_event_class`.

  A missing `window` means "from the question's creation to its deadline".
  """
  use ForecastLoop.Schema

  @statuses ~w(draft review live resolved void)
  @series_ops ~w(>= <= > <)
  @series_at ~w(end_of_window any_in_window mean_in_window)
  @events_ops ~w(count>= count<=)
  @fip_fields [:event_definition, :resolution_condition, :deadline, :domain]

  schema "questions" do
    field :title, :string
    field :event_definition, :string
    field :resolution_condition, :map
    field :deadline, :utc_datetime_usec
    field :domain, :string
    field :status, :string, default: "draft"
    field :template_period, :string
    field :asserted_by, :string
    belongs_to :created_by, ForecastLoop.Ledger.Agent
    belongs_to :reviewed_by, ForecastLoop.Ledger.Agent
    belongs_to :template, ForecastLoop.Ledger.QuestionTemplate
    has_many :forecasts, ForecastLoop.Ledger.Forecast
    has_one :resolution, ForecastLoop.Ledger.Resolution
    timestamps()
  end

  @doc "The four Forecast Integrity Protocol fields."
  def fip_fields, do: @fip_fields

  @doc "Changeset for a draft. FIP fields are optional; their shape is checked when present."
  def changeset(question, attrs) do
    question
    |> cast(attrs, [
      :title,
      :event_definition,
      :resolution_condition,
      :deadline,
      :domain,
      :status,
      :created_by_id,
      :reviewed_by_id,
      :template_id,
      :template_period
    ])
    |> ForecastLoop.Schema.provenance(attrs)
    |> validate_required([:title, :created_by_id])
    |> validate_inclusion(:status, @statuses)
    |> validate_change(:resolution_condition, fn :resolution_condition, rc ->
      case validate_resolution_condition(rc) do
        :ok -> []
        {:error, msg} -> [resolution_condition: msg]
      end
    end)
    |> check_constraint(:status,
      name: :fip_before_live,
      message: "FIP fields and an independent reviewer are required"
    )
    |> check_constraint(:resolution_condition, name: :resolution_condition_shape)
    |> foreign_key_constraint(:created_by_id)
    |> foreign_key_constraint(:reviewed_by_id)
    |> unique_constraint([:template_id, :template_period])
  end

  @doc "Changeset that also requires all four FIP fields. MCP and the UI use it to create questions."
  def fip_changeset(question, attrs) do
    question
    |> changeset(attrs)
    |> validate_required(@fip_fields, message: "is a required Forecast Integrity Protocol field")
  end

  @doc "Checks the shape of a resolution condition."
  @spec validate_resolution_condition(term()) :: :ok | {:error, String.t()}
  def validate_resolution_condition(%{"type" => "manual"}), do: :ok

  def validate_resolution_condition(%{"type" => "series"} = rc) do
    common_checks(rc, @series_ops) ||
      if rc["at"] in @series_at,
        do: :ok,
        else: {:error, "at must be one of #{Enum.join(@series_at, ", ")}"}
  end

  def validate_resolution_condition(%{"type" => "events"} = rc) do
    common_checks(rc, @events_ops) ||
      if is_map(Map.get(rc, "where", %{})),
        do: :ok,
        else: {:error, "where must be a map of attribute to value or list of values"}
  end

  def validate_resolution_condition(_),
    do: {:error, "type must be one of manual, series, events"}

  defp common_checks(rc, ops) do
    cond do
      not is_integer(rc["signal_id"]) ->
        {:error, "signal_id must be an integer"}

      rc["op"] not in ops ->
        {:error, "op must be one of #{Enum.join(ops, ", ")}"}

      not is_number(rc["value"]) ->
        {:error, "value must be a number"}

      not valid_window?(rc["window"]) ->
        {:error, "window must be a map with from/to ISO 8601 timestamps"}

      true ->
        nil
    end
  end

  defp valid_window?(nil), do: true

  defp valid_window?(w) when is_map(w) do
    Enum.all?(Map.take(w, ["from", "to"]), fn {_k, v} ->
      match?({:ok, _, _}, DateTime.from_iso8601(to_string(v)))
    end)
  end

  defp valid_window?(_), do: false
end
