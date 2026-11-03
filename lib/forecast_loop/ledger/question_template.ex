defmodule ForecastLoop.Ledger.QuestionTemplate do
  @moduledoc """
  A standing question. For each period of `cadence`, the batch makes one question
  from the patterns and puts it in `review` status. A person still reviews it
  before it goes live.

  Patterns can use these placeholders (see docs/adr/0008):
  `{{period}}` (for example `2026-Q4`, `2026-11`, `2026-W45`),
  `{{period_start}}`, `{{period_end}}` (ISO 8601 timestamps), and
  `{{param.<name>}}` for each key in `params`.
  `resolution_condition_pattern` is JSON; its string values use the same
  placeholders, and its window defaults to the period.
  """
  use ForecastLoop.Schema

  schema "question_templates" do
    field :key, :string
    field :domain, :string
    field :title_pattern, :string
    field :event_definition_pattern, :string
    field :resolution_condition_pattern, :map
    field :cadence, :string
    field :window_length, :string
    field :params, :map, default: %{}
    field :starts_on, :date
    field :active, :boolean, default: true
    field :pack, :string
    field :asserted_by, :string
    belongs_to :created_by, ForecastLoop.Ledger.Agent
    timestamps()
  end

  @fields [
    :key,
    :domain,
    :title_pattern,
    :event_definition_pattern,
    :resolution_condition_pattern,
    :cadence,
    :window_length,
    :params,
    :starts_on,
    :active,
    :pack,
    :created_by_id
  ]

  def changeset(template, attrs) do
    template
    |> cast(attrs, @fields)
    |> ForecastLoop.Schema.provenance(attrs)
    |> validate_required(@fields -- [:params, :active, :pack])
    |> validate_inclusion(:cadence, ~w(weekly monthly quarterly))
    |> validate_format(:window_length, ~r/^P(\d+[YMWD])+$/,
      message: "must be an ISO 8601 date duration such as P1M or P3M"
    )
    |> unique_constraint(:key)
  end
end
