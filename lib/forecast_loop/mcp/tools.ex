defmodule ForecastLoop.MCP.Tools do
  @moduledoc """
  The tools that the MCP server offers. Each tool has a JSON Schema for its
  arguments; `call/2` validates the arguments against it before it acts.

  Agents are named, not numbered: a tool that records who did something takes an
  agent name and creates the agent if it does not exist (`kind` defaults to `llm`
  for forecasts and `human` for reviews and authorship). `create_question` refuses
  a question without all four Forecast Integrity Protocol fields.
  """
  alias ForecastLoop.{Batch, Knowledge, Ledger, Packs, Repo, Rules, Signals, Sources}
  alias ForecastLoop.Knowledge.Fact
  alias ForecastLoop.MCP.Validate

  @kinds ~w(human model llm)
  @time %{"type" => "string", "format" => "date-time"}
  @agent_kind %{"type" => "string", "enum" => @kinds}

  @doc "The tool list for `tools/list`."
  def definitions do
    for {name, desc, schema} <- specs(),
        do: %{"name" => name, "description" => desc, "inputSchema" => schema}
  end

  defp obj(props, required \\ []),
    do: %{
      "type" => "object",
      "properties" => props,
      "required" => required,
      "additionalProperties" => false
    }

  defp specs do
    [
      {"list_packs",
       "List installed domain packs with the rows each contributed, and the pack folders that can be installed.",
       obj(%{})},
      {"install_pack", "Install a pack folder from priv/packs/<name> (idempotent).",
       obj(%{"name" => %{"type" => "string"}}, ["name"])},
      {"create_pack",
       "Start a new pack in the application (the pack builder). Then add signals, knowledge, templates and scenarios with `pack` set to its name.",
       obj(
         %{
           "name" => %{"type" => "string"},
           "title" => %{"type" => "string"},
           "description" => %{"type" => "string"},
           "author" => %{"type" => "string"}
         },
         ["name", "title", "author"]
       )},
      {"export_pack", "Write a pack's rows to a folder in the import format.",
       obj(%{"name" => %{"type" => "string"}, "dir" => %{"type" => "string"}}, ["name", "dir"])},
      {"list_sources", "List source systems with the spec keys each one reads.", obj(%{})},
      {"preview_spec", "Fetch a sample of rows for a source spec without storing anything.",
       obj(%{"spec" => %{"type" => "object"}}, ["spec"])},
      {"register_signal",
       "Register a signal. kind: series, events or derived. source_spec.system names the source.",
       obj(
         %{
           "name" => %{"type" => "string"},
           "kind" => %{"type" => "string", "enum" => ~w(series events derived)},
           "source_spec" => %{"type" => "object"},
           "domain" => %{"type" => "string"},
           "cadence" => %{"type" => "string"},
           "units" => %{"type" => "string"},
           "definition_notes" => %{"type" => "string"},
           "pack" => %{"type" => "string"},
           "author" => %{"type" => "string"}
         },
         ["name", "kind", "source_spec", "author"]
       )},
      {"list_signals", "List signals, optionally by domain, kind or pack.",
       obj(%{
         "domain" => %{"type" => "string"},
         "kind" => %{"type" => "string"},
         "pack" => %{"type" => "string"}
       })},
      {"list_knowledge",
       "List knowledge facts, optionally by predicate, domain, pack or subject.",
       obj(%{
         "predicate" => %{"type" => "string", "enum" => Fact.predicates()},
         "domain" => %{"type" => "string"},
         "pack" => %{"type" => "string"},
         "subject" => %{"type" => "string"}
       })},
      {"assert_knowledge",
       "Assert a knowledge fact predicate(subject, object), valid in [valid_from, valid_to). Only the core predicates are allowed.",
       obj(
         %{
           "predicate" => %{"type" => "string", "enum" => Fact.predicates()},
           "subject" => %{"type" => "string"},
           "object" => %{"type" => "string"},
           "attributes" => %{"type" => "object"},
           "valid_from" => @time,
           "valid_to" => @time,
           "domain" => %{"type" => "string"},
           "pack" => %{"type" => "string"},
           "note" => %{"type" => "string"},
           "author" => %{"type" => "string"}
         },
         ["predicate", "subject", "object", "author"]
       )},
      {"list_gaps",
       "List open gap work items: what the system needs but lacks. Optionally only one gap rule (for example gap_unknown_entity).",
       obj(%{"rule" => %{"type" => "string"}})},
      {"create_question",
       "Create a question in review. Requires all four Forecast Integrity Protocol fields: event_definition, resolution_condition, deadline, domain. A different agent must review it before it goes live.",
       obj(
         %{
           "title" => %{"type" => "string"},
           "event_definition" => %{"type" => "string"},
           "resolution_condition" => %{"type" => "object"},
           "deadline" => @time,
           "domain" => %{"type" => "string"},
           "author" => %{"type" => "string"},
           "author_kind" => @agent_kind
         },
         ["title", "event_definition", "resolution_condition", "deadline", "domain", "author"]
       )},
      {"review_question",
       "Record a reviewer for a question in review. The reviewer must not be its author. The next batch run makes it live.",
       obj(
         %{
           "question_id" => %{"type" => "integer"},
           "reviewer" => %{"type" => "string"},
           "reviewer_kind" => @agent_kind
         },
         ["question_id", "reviewer"]
       )},
      {"create_template",
       "Create a question template that the batch turns into one question for each period.",
       obj(
         %{
           "key" => %{"type" => "string"},
           "domain" => %{"type" => "string"},
           "title_pattern" => %{"type" => "string"},
           "event_definition_pattern" => %{"type" => "string"},
           "resolution_condition_pattern" => %{"type" => "object"},
           "cadence" => %{"type" => "string", "enum" => ~w(weekly monthly quarterly)},
           "window_length" => %{"type" => "string"},
           "params" => %{"type" => "object"},
           "starts_on" => %{"type" => "string", "format" => "date"},
           "pack" => %{"type" => "string"},
           "author" => %{"type" => "string"}
         },
         ~w(key domain title_pattern event_definition_pattern resolution_condition_pattern cadence window_length starts_on author)
       )},
      {"list_questions",
       "List questions, optionally by status, domain, or deadline before a time.",
       obj(%{
         "status" => %{"type" => "string", "enum" => ~w(draft review live resolved void)},
         "domain" => %{"type" => "string"},
         "due_before" => @time
       })},
      {"submit_forecast",
       "Append a forecast (a probability that the question resolves true). Forecasts are append-only; a revision is a new forecast.",
       obj(
         %{
           "question_id" => %{"type" => "integer"},
           "agent" => %{"type" => "string"},
           "agent_kind" => @agent_kind,
           "probability" => %{"type" => "number", "minimum" => 0, "maximum" => 1},
           "rationale" => %{"type" => "string"},
           "cited_signal_ids" => %{"type" => "array", "items" => %{"type" => "integer"}}
         },
         ["question_id", "agent", "probability", "rationale"]
       )},
      {"resolve_question",
       "Resolve a question by hand, with the source and evidence of the outcome.",
       obj(
         %{
           "question_id" => %{"type" => "integer"},
           "outcome" => %{"type" => "boolean"},
           "source" => %{"type" => "string"},
           "evidence" => %{"type" => "object"},
           "resolved_by" => %{"type" => "string"}
         },
         ["question_id", "outcome", "source", "resolved_by"]
       )},
      {"calibration_report",
       "Calibration per agent and domain (Brier, log score, skill, Murphy decomposition) with decile buckets.",
       obj(%{"agent" => %{"type" => "string"}, "domain" => %{"type" => "string"}})},
      {"list_work_items", "List work items, optionally by kind and status (default open).",
       obj(%{
         "kind" => %{"type" => "string"},
         "status" => %{"type" => "string", "enum" => ~w(open done dismissed)}
       })},
      {"query",
       "Run a read-only SQL query against the rules schema (views k_*, gap_*, loop_*, cal_*). Returns the SQL with the rows.",
       obj(
         %{
           "sql" => %{"type" => "string"},
           "timeout_ms" => %{"type" => "integer", "minimum" => 1, "maximum" => 30_000}
         },
         ["sql"]
       )}
    ]
  end

  @doc "Validates the arguments and runs the tool. Returns `{:ok, data}` or `{:error, message_or_errors}`."
  @spec call(String.t(), map()) :: {:ok, term()} | {:error, term()}
  def call(name, args) do
    case List.keyfind(specs(), name, 0) do
      nil ->
        {:error, "unknown tool #{name}"}

      {_, _, schema} ->
        with :ok <- Validate.validate(args, schema), do: run(name, args)
    end
  end

  defp agent!(name, kind) do
    {:ok, a} = Ledger.ensure_agent(name, kind, "mcp")
    a
  end

  defp by(args),
    do:
      "mcp:" <>
        (args["author"] || args["agent"] || args["reviewer"] || args["resolved_by"] || "unknown")

  defp run("list_packs", _),
    do:
      {:ok,
       %{
         "installed" =>
           Enum.map(
             Packs.list_packs(),
             &%{
               "name" => &1.pack.name,
               "title" => &1.pack.title,
               "status" => &1.pack.status,
               "contributions" => &1.contributions
             }
           ),
         "available" => Packs.available()
       }}

  defp run("install_pack", %{"name" => n}), do: Packs.install(n, asserted_by: "mcp")

  defp run("create_pack", a),
    do:
      changeset_result(
        Packs.create_pack(%{
          name: a["name"],
          title: a["title"],
          description: a["description"] || "",
          asserted_by: by(a)
        })
      )

  defp run("export_pack", %{"name" => n, "dir" => d}),
    do: with(:ok <- Packs.export(n, d), do: {:ok, %{"exported_to" => d}})

  defp run("list_sources", _), do: {:ok, Enum.map(Sources.list(), &Map.delete(&1, :module))}
  defp run("preview_spec", %{"spec" => spec}), do: Sources.preview(spec)

  defp run("register_signal", a),
    do:
      changeset_result(
        Signals.register_signal(a |> Map.delete("author") |> Map.put("asserted_by", by(a)))
      )

  defp run("list_signals", a),
    do:
      {:ok,
       Signals.list_signals(domain: a["domain"], kind: a["kind"], pack: a["pack"])
       |> Enum.map(&row/1)}

  defp run("list_knowledge", a),
    do:
      {:ok,
       Knowledge.list_facts(
         predicate: a["predicate"],
         domain: a["domain"],
         pack: a["pack"],
         subject: a["subject"]
       )
       |> Enum.map(&row/1)}

  defp run("assert_knowledge", a),
    do:
      changeset_result(
        Knowledge.assert_fact(a |> Map.delete("author") |> Map.put("asserted_by", by(a)))
      )

  defp run("list_gaps", a) do
    items =
      Batch.list_work_items(kind: "gap")
      |> Enum.filter(&(is_nil(a["rule"]) or &1.subject_type == a["rule"]))

    {:ok, Enum.map(items, &row/1)}
  end

  defp run("create_question", a) do
    author = agent!(a["author"], a["author_kind"] || "human")

    a
    |> Map.drop(["author", "author_kind"])
    |> Map.merge(%{"created_by_id" => author.id, "asserted_by" => by(a)})
    |> Ledger.create_question()
    |> changeset_result()
  end

  defp run("review_question", %{"question_id" => id} = a) do
    reviewer = agent!(a["reviewer"], a["reviewer_kind"] || "human")

    case Repo.get(Ledger.Question, id) do
      %{status: "review", created_by_id: author} = q when author != reviewer.id ->
        changeset_result(Ledger.review_question(q, reviewer, by(a)))

      %{status: "review"} ->
        {:error, "the reviewer must not be the question's author"}

      %{status: s} ->
        {:error, "question #{id} is #{s}, not in review"}

      nil ->
        {:error, "no question #{id}"}
    end
  end

  defp run("create_template", a) do
    author = agent!(a["author"], "human")

    changeset_result(
      Ledger.create_template(
        a
        |> Map.delete("author")
        |> Map.merge(%{"created_by_id" => author.id, "asserted_by" => by(a)})
      )
    )
  end

  defp run("list_questions", a) do
    due = a["due_before"] && elem(DateTime.from_iso8601(a["due_before"]), 1)

    {:ok,
     Ledger.list_questions(status: a["status"], domain: a["domain"], due_before: due)
     |> Enum.map(&row/1)}
  end

  defp run("submit_forecast", a) do
    agent = agent!(a["agent"], a["agent_kind"] || "llm")

    case Repo.get(Ledger.Question, a["question_id"]) do
      %{status: "live"} ->
        Ledger.submit_forecast(%{
          question_id: a["question_id"],
          agent_id: agent.id,
          probability: a["probability"] * 1.0,
          rationale: a["rationale"],
          cited_signal_ids: a["cited_signal_ids"] || [],
          asserted_by: by(a)
        })
        |> changeset_result()

      %{status: s} ->
        {:error, "question #{a["question_id"]} is #{s}; forecasts go on live questions"}

      nil ->
        {:error, "no question #{a["question_id"]}"}
    end
  end

  defp run("resolve_question", a) do
    case Repo.get(Ledger.Question, a["question_id"]) do
      %{status: "live"} = q ->
        Ledger.resolve_question(q, %{
          outcome: a["outcome"],
          resolved_at: DateTime.utc_now(),
          source: a["source"],
          evidence: a["evidence"] || %{},
          resolved_by: a["resolved_by"],
          asserted_by: by(a)
        })
        |> changeset_result()

      %{status: s} ->
        {:error, "question #{a["question_id"]} is #{s}, not live"}

      nil ->
        {:error, "no question #{a["question_id"]}"}
    end
  end

  defp run("calibration_report", a) do
    keep = fn r ->
      (is_nil(a["agent"]) or r["agent_name"] == a["agent"]) and
        (is_nil(a["domain"]) or r["domain"] == a["domain"])
    end

    names = Map.new(Ledger.list_agents(), &{&1.id, &1.name})

    buckets =
      Rules.rows("cal_bucket") |> Enum.map(&Map.put(&1, "agent_name", names[&1["agent_id"]]))

    {:ok,
     %{
       "as_of" => Batch.as_of(),
       "summary" => Enum.filter(Rules.rows("cal_summary"), keep),
       "buckets" => Enum.filter(buckets, keep)
     }}
  end

  defp run("list_work_items", a),
    do:
      {:ok,
       Batch.list_work_items(kind: a["kind"], status: a["status"] || "open") |> Enum.map(&row/1)}

  defp run("query", a), do: Rules.query(a["sql"], timeout_ms: a["timeout_ms"] || 5_000)

  defp changeset_result({:ok, struct}), do: {:ok, row(struct)}

  defp changeset_result({:error, %Ecto.Changeset{} = cs}),
    do:
      {:error,
       Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
         Enum.reduce(opts, msg, fn {k, v}, m -> String.replace(m, "%{#{k}}", to_string(v)) end)
       end)}

  defp changeset_result(other), do: other

  @doc false
  # A schema struct as a plain map, without Ecto metadata or unloaded associations.
  def row(%{__struct__: mod} = s) do
    s
    |> Map.from_struct()
    |> Map.drop([:__meta__])
    |> Map.reject(fn {_k, v} -> match?(%Ecto.Association.NotLoaded{}, v) end)
    |> Map.new(fn {k, v} ->
      {k,
       if(is_struct(v) and not is_struct(v, DateTime) and not is_struct(v, Date),
         do: row(v),
         else: v
       )}
    end)
    |> Map.put(:type, mod |> Module.split() |> List.last())
  end
end
