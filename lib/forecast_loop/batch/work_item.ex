defmodule ForecastLoop.Batch.WorkItem do
  @moduledoc """
  A task for a person, opened by the batch from a rule view row. At most one open
  item exists for each (kind, subject_type, subject_id).
  """
  use ForecastLoop.Schema

  schema "work_items" do
    field :kind, :string
    field :subject_type, :string
    field :subject_id, :string
    field :payload, :map, default: %{}
    field :status, :string, default: "open"
    field :asserted_by, :string
    belongs_to :run, ForecastLoop.Batch.Run
    timestamps()
  end
end
