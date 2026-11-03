defmodule ForecastLoop.Pack do
  @moduledoc """
  A domain pack: the data that gives the domain-neutral core its meaning for one
  subject area. A user builds a pack in the application, or imports one from a
  folder. Rows that a pack contributes carry its `name` in their `pack` column.
  See docs/adr/0009.
  """
  use ForecastLoop.Schema

  schema "packs" do
    field :name, :string
    field :title, :string
    field :description, :string, default: ""
    field :status, :string, default: "draft"
    field :origin, :string, default: "builder"
    field :asserted_by, :string
    timestamps()
  end

  def changeset(pack, attrs) do
    pack
    |> cast(attrs, [:name, :title, :description, :status, :origin])
    |> ForecastLoop.Schema.provenance(attrs)
    |> validate_required([:name, :title])
    |> validate_format(:name, ~r/^[a-z][a-z0-9_]*$/)
    |> validate_inclusion(:status, ~w(draft active archived))
    |> validate_inclusion(:origin, ~w(builder import))
    |> unique_constraint(:name)
  end
end
