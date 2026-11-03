defmodule ForecastLoop.Schema do
  @moduledoc """
  Common setup for every ForecastLoop Ecto schema: microsecond UTC timestamps and
  the `asserted_by` provenance field, which names who or what wrote the row.
  """

  defmacro __using__(_opts) do
    quote do
      use Ecto.Schema
      import Ecto.Changeset
      @timestamps_opts [type: :utc_datetime_usec]
    end
  end

  @doc "Casts and requires `asserted_by` on a changeset."
  @spec provenance(Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def provenance(changeset, attrs) do
    changeset
    |> Ecto.Changeset.cast(attrs, [:asserted_by])
    |> Ecto.Changeset.validate_required([:asserted_by])
  end
end
