defmodule ForecastLoop.Knowledge.Fact do
  @moduledoc """
  A hand-asserted fact `predicate(subject, object)`, valid in
  `[valid_from, valid_to)`. A NULL bound means "unbounded". The `k_*` rule views
  apply these facts to raw observations. Knowledge facts are the only place where
  domain meaning enters the core.

  The core interprets exactly the predicates in `predicates/0`. A pack supplies
  rows for them and never adds a predicate; a database CHECK constraint enforces
  this.
  """
  use ForecastLoop.Schema

  @predicates ~w(value_alias class_rule link_rule entity_alias entity_attr entity_domain same_as min_history)

  @doc "The knowledge predicates that the core rule views interpret."
  def predicates, do: @predicates

  schema "knowledge_facts" do
    field :predicate, :string
    field :subject, :string
    field :object, :string
    field :attributes, :map, default: %{}
    field :valid_from, :utc_datetime_usec
    field :valid_to, :utc_datetime_usec
    field :domain, :string
    field :pack, :string
    field :note, :string
    field :asserted_by, :string
    timestamps()
  end

  def changeset(fact, attrs) do
    fact
    |> cast(attrs, [
      :predicate,
      :subject,
      :object,
      :attributes,
      :valid_from,
      :valid_to,
      :domain,
      :pack,
      :note
    ])
    |> ForecastLoop.Schema.provenance(attrs)
    |> validate_required([:predicate, :subject, :object])
    |> validate_inclusion(:predicate, @predicates)
    |> check_constraint(:predicate, name: :predicate_known)
    |> check_constraint(:valid_to, name: :valid_range, message: "must be after valid_from")
    |> unique_constraint([:predicate, :subject, :object, :valid_from],
      name: :knowledge_facts_identity
    )
  end
end
