defmodule ForecastLoop.Ledger do
  @moduledoc """
  The forecast ledger: scenarios, assumptions, questions, agents, model versions,
  forecasts and resolutions.

  Question life cycle: `draft` → `review` (all four FIP fields present) → `live`
  (promoted by the batch from the `rules.loop_live_question` view) → `resolved`.
  This module performs the writes; the rule views decide which writes to make.
  """
  import Ecto.Query
  alias ForecastLoop.Repo

  alias ForecastLoop.Ledger.{
    Agent,
    Assumption,
    Forecast,
    ModelVersion,
    Question,
    QuestionTemplate,
    Resolution,
    Scenario
  }

  # ------------------------------------------------------------------ agents

  def create_agent(attrs), do: %Agent{} |> Agent.changeset(attrs) |> Repo.insert()

  @doc "Returns the agent with `name`, creating it with `kind` if it does not exist."
  def ensure_agent(name, kind, asserted_by \\ "system") do
    case Repo.get_by(Agent, name: name) do
      nil -> create_agent(%{name: name, kind: kind, asserted_by: asserted_by})
      agent -> {:ok, agent}
    end
  end

  def get_agent!(id), do: Repo.get!(Agent, id)
  def list_agents, do: Repo.all(from a in Agent, order_by: a.name)

  # ---------------------------------------------------------- model versions

  def create_model_version(attrs),
    do: %ModelVersion{} |> ModelVersion.changeset(attrs) |> Repo.insert()

  def get_model_version!(id), do: Repo.get!(ModelVersion, id)
  def list_model_versions, do: Repo.all(from m in ModelVersion, order_by: m.id)

  # --------------------------------------------------------------- scenarios

  def create_scenario(attrs), do: %Scenario{} |> Scenario.changeset(attrs) |> Repo.insert()

  def create_assumption(attrs),
    do: %Assumption{} |> Assumption.changeset(attrs) |> Repo.insert()

  def list_scenarios,
    do: Repo.all(from s in Scenario, order_by: s.id, preload: :assumptions)

  # --------------------------------------------------------------- templates

  def create_template(attrs),
    do: %QuestionTemplate{} |> QuestionTemplate.changeset(attrs) |> Repo.insert()

  def list_templates, do: Repo.all(from t in QuestionTemplate, order_by: t.key)

  # --------------------------------------------------------------- questions

  @doc "Creates a draft question. FIP fields are optional for a draft."
  def create_draft_question(attrs),
    do: %Question{} |> Question.changeset(attrs) |> Repo.insert()

  @doc "Creates a question in `review` status. Requires all four FIP fields."
  def create_question(attrs) do
    attrs = Map.put(stringify(attrs), "status", "review")
    %Question{} |> Question.fip_changeset(attrs) |> Repo.insert()
  end

  @doc "Moves a draft to `review`. Requires all four FIP fields."
  def submit_for_review(%Question{status: "draft"} = q, asserted_by) do
    q |> Question.fip_changeset(%{status: "review", asserted_by: asserted_by}) |> Repo.update()
  end

  @doc """
  Records `reviewer` as the reviewer. Does not make the question live: the batch
  promotes it when `rules.loop_live_question` lists it.
  """
  def review_question(%Question{status: "review"} = q, %Agent{id: reviewer_id}, asserted_by) do
    q
    |> Question.fip_changeset(%{reviewed_by_id: reviewer_id, asserted_by: asserted_by})
    |> Repo.update()
  end

  def get_question!(id), do: Repo.get!(Question, id)

  def get_question_with_history!(id) do
    Question
    |> Repo.get!(id)
    |> Repo.preload([
      :created_by,
      :reviewed_by,
      :resolution,
      forecasts: from(f in Forecast, order_by: [asc: f.made_at, asc: f.id], preload: :agent)
    ])
  end

  @doc "Lists questions. Options: `:status`, `:domain`, `:due_before` (DateTime)."
  def list_questions(opts \\ []) do
    Question
    |> filter(:status, opts[:status])
    |> filter(:domain, opts[:domain])
    |> then(fn q ->
      case opts[:due_before] do
        nil -> q
        t -> where(q, [x], x.deadline <= ^t)
      end
    end)
    |> order_by([x], asc_nulls_last: x.deadline, asc: x.id)
    |> Repo.all()
  end

  defp filter(q, _field, nil), do: q
  defp filter(q, field, value), do: where(q, [x], field(x, ^field) == ^value)

  # --------------------------------------------------------------- forecasts

  @doc "Appends a forecast. Forecasts are append-only; a revision is a new row."
  def submit_forecast(attrs) do
    attrs = stringify(attrs) |> Map.put_new_lazy("made_at", &DateTime.utc_now/0)
    %Forecast{} |> Forecast.changeset(attrs) |> Repo.insert()
  end

  # ------------------------------------------------------------- resolutions

  @doc "Records the outcome of a question and marks it `resolved`, in one transaction."
  def resolve_question(%Question{} = q, attrs) do
    Repo.transact(fn ->
      with {:ok, res} <-
             %Resolution{}
             |> Resolution.changeset(Map.put(stringify(attrs), "question_id", q.id))
             |> Repo.insert(),
           {:ok, _q} <-
             q
             |> Question.changeset(%{status: "resolved", asserted_by: res.asserted_by})
             |> Repo.update() do
        {:ok, res}
      end
    end)
  end

  defp stringify(attrs), do: Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
end
