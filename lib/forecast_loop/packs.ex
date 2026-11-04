defmodule ForecastLoop.Packs do
  @moduledoc """
  Domain packs (docs/adr/0009). A pack is data in the database: a `packs` row, and
  rows in other tables that carry the pack's name in their `pack` column. A person
  builds a pack in the application (UI or MCP), or imports a folder.

  ## Folder format (import and export)

      pack.json        {"name", "title", "description"}
      signals.json     [{"name", "domain", "kind", "cadence", "units", "definition_notes", "source_spec"}]
      derived.json     [{"name", "domain", "cadence", "units", "definition_notes", "spec"}]
                       spec = a declarative derived operation (ForecastLoop.Sources.Derived)
      knowledge/*.csv  knowledge facts (ForecastLoop.Knowledge.import_csv/2)
      templates.json   [{"key", "domain", "title_pattern", "event_definition_pattern",
                         "resolution_condition_pattern", "cadence", "window_length",
                         "params", "starts_on", "active"}]
      models.json      [{"agent", "model_module", "version", "domains", "params", "notes"}]
      scenarios.md     "## Title" starts a scenario, "Domain: x" sets its domain,
                       "- statement" lines are assumptions, other lines are narrative
      README.md        what the pack forecasts and what its facts mean
      vocabulary.txt   words that belong to the pack (the core-purity test reads them)

  Every file except `pack.json` is optional. A pack adds rows only: it cannot add
  rule views, predicates or schema. Installing the same folder again changes nothing.
  The author of a pack's templates is the agent `pack:<name>`.
  """
  import Ecto.Query
  alias ForecastLoop.{Knowledge, Ledger, Pack, Repo, Signals}
  alias ForecastLoop.Knowledge.Fact
  alias ForecastLoop.Ledger.{Assumption, ModelVersion, QuestionTemplate, Scenario}
  alias ForecastLoop.Signals.Signal

  @contribution_tables [
    {"signals", Signal},
    {"knowledge_facts", Fact},
    {"question_templates", QuestionTemplate},
    {"model_versions", ModelVersion},
    {"scenarios", Scenario}
  ]

  # ------------------------------------------------------------------ read

  @doc "Folder names under `priv/packs/` that can be installed."
  @spec available() :: [String.t()]
  def available do
    Path.join(:code.priv_dir(:forecast_loop), "packs/*/pack.json")
    |> Path.wildcard()
    |> Enum.map(&(&1 |> Path.dirname() |> Path.basename()))
    |> Enum.sort()
  end

  @doc "Installed packs with the number of rows each contributed."
  @spec list_packs() :: [%{pack: Pack.t(), contributions: map()}]
  def list_packs do
    Repo.all(from p in Pack, order_by: p.name)
    |> Enum.map(&%{pack: &1, contributions: contributions(&1.name)})
  end

  def get_pack(name), do: Repo.get_by(Pack, name: name)

  @doc "Row counts that a pack contributed, for each table."
  @spec contributions(String.t()) :: %{String.t() => non_neg_integer()}
  def contributions(name) do
    Map.new(@contribution_tables, fn {table, schema} ->
      {table, Repo.aggregate(from(x in schema, where: x.pack == ^name), :count)}
    end)
  end

  # --------------------------------------------------------------- builder

  @doc "Creates an empty pack (the first step of the in-app builder)."
  def create_pack(attrs), do: %Pack{} |> Pack.changeset(attrs) |> Repo.insert()

  # ----------------------------------------------------------------- install

  @doc """
  Installs a pack folder: a name under `priv/packs/`, or a directory path.
  Runs in one transaction. Returns `{:ok, summary}` or `{:error, reason}`.
  """
  @spec install(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def install(name_or_dir, opts \\ []) do
    dir =
      if File.dir?(name_or_dir),
        do: name_or_dir,
        else: Path.join(:code.priv_dir(:forecast_loop), "packs/" <> name_or_dir)

    asserted_by = Keyword.get(opts, :asserted_by, "pack_install")

    with {:ok, meta} <- read_json(dir, "pack.json", :required) do
      Repo.transact(fn -> do_install(dir, meta, asserted_by) end)
    end
  end

  defp do_install(dir, %{"name" => name} = meta, by) do
    with {:ok, _pack} <- upsert_pack(meta, by),
         {:ok, author} <- Ledger.ensure_agent("pack:" <> name, "model", by),
         {:ok, signals} <- read_json(dir, "signals.json", []),
         {:ok, derived} <- read_json(dir, "derived.json", []),
         {:ok, templates} <- read_json(dir, "templates.json", []),
         {:ok, models} <- read_json(dir, "models.json", []),
         {:ok, s1} <- each(signals, &upsert_signal(&1, name, by)),
         {:ok, s2} <- each(derived, &upsert_signal(derived_signal(&1), name, by)),
         {:ok, facts} <- import_knowledge(dir, name, by),
         {:ok, t} <- each(templates, &upsert_template(&1, name, author, by)),
         {:ok, m} <- each(models, &upsert_model(&1, name, by)),
         {:ok, sc} <- install_scenarios(dir, name, by) do
      {:ok,
       %{
         "pack" => name,
         "signals_changed" => s1 + s2,
         "facts" => facts,
         "templates_changed" => t,
         "models_changed" => m,
         "scenarios_added" => sc
       }}
    end
  end

  defp do_install(_dir, _meta, _by), do: {:error, :pack_json_needs_name}

  defp upsert_pack(meta, by) do
    attrs = %{
      name: meta["name"],
      title: meta["title"] || meta["name"],
      description: meta["description"] || "",
      status: "active",
      origin: "import",
      asserted_by: by
    }

    case get_pack(meta["name"]) do
      nil -> create_pack(attrs)
      pack -> update_if_changed(pack, Pack.changeset(pack, Map.delete(attrs, :asserted_by)))
    end
  end

  defp derived_signal(d) do
    d
    |> Map.drop(["spec"])
    |> Map.merge(%{
      "kind" => "derived",
      "source_spec" => Map.put(d["spec"] || %{}, "system", "derived")
    })
  end

  defp upsert_signal(attrs, pack, by) do
    attrs = Map.merge(attrs, %{"pack" => pack, "asserted_by" => by})

    case Signals.get_by_name(attrs["name"]) do
      nil ->
        with {:ok, _} <- Signals.register_signal(attrs), do: {:ok, 1}

      %Signal{pack: ^pack} = s ->
        update_if_changed(s, Signal.changeset(s, Map.delete(attrs, "asserted_by")))

      %Signal{pack: other} ->
        {:error, {:signal_belongs_to_another_pack, attrs["name"], other}}
    end
  end

  defp upsert_template(attrs, pack, author, by) do
    attrs =
      attrs
      |> Map.merge(%{"pack" => pack, "created_by_id" => author.id, "asserted_by" => by})
      |> Map.put_new("params", %{})

    case Repo.get_by(QuestionTemplate, key: attrs["key"]) do
      nil ->
        with {:ok, _} <- Ledger.create_template(attrs), do: {:ok, 1}

      %QuestionTemplate{pack: ^pack} = t ->
        update_if_changed(t, QuestionTemplate.changeset(t, Map.delete(attrs, "asserted_by")))

      %QuestionTemplate{pack: other} ->
        {:error, {:template_belongs_to_another_pack, attrs["key"], other}}
    end
  end

  defp upsert_model(attrs, pack, by) do
    with {:ok, agent} <-
           Ledger.ensure_agent(attrs["agent"] || "model:" <> attrs["model_module"], "model", by) do
      mv_attrs = Map.merge(attrs, %{"agent_id" => agent.id, "pack" => pack, "asserted_by" => by})

      save_model(
        Repo.get_by(ModelVersion, agent_id: agent.id, version: attrs["version"]),
        mv_attrs
      )
    end
  end

  defp save_model(nil, attrs) do
    with {:ok, _} <- Ledger.create_model_version(attrs), do: {:ok, 1}
  end

  defp save_model(mv, attrs),
    do: update_if_changed(mv, ModelVersion.changeset(mv, Map.delete(attrs, "asserted_by")))

  defp import_knowledge(dir, pack, by) do
    dir
    |> Path.join("knowledge/*.csv")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.reduce_while({:ok, 0}, fn file, {:ok, n} ->
      case Knowledge.import_csv(file, pack: pack, asserted_by: by) do
        {:ok, k} -> {:cont, {:ok, n + k}}
        {:error, reason} -> {:halt, {:error, {:knowledge, Path.basename(file), reason}}}
      end
    end)
  end

  defp install_scenarios(dir, pack, by) do
    path = Path.join(dir, "scenarios.md")

    if File.exists?(path) do
      path |> File.read!() |> parse_scenarios() |> each(&add_scenario(&1, pack, by))
    else
      {:ok, 0}
    end
  end

  defp add_scenario(sc, pack, by) do
    if Repo.exists?(from s in Scenario, where: s.title == ^sc.title and s.pack == ^pack),
      do: {:ok, 0},
      else: create_scenario(sc, pack, by)
  end

  defp create_scenario(sc, pack, by) do
    attrs = %{
      title: sc.title,
      narrative: sc.narrative,
      domain: sc.domain,
      pack: pack,
      asserted_by: by
    }

    with {:ok, s} <- Ledger.create_scenario(attrs) do
      Enum.each(sc.assumptions, fn a ->
        {:ok, _} = Ledger.create_assumption(%{scenario_id: s.id, statement: a, asserted_by: by})
      end)

      {:ok, 1}
    end
  end

  @doc false
  # Parses scenarios.md. See the module doc for the format.
  def parse_scenarios(text) do
    text
    |> String.split("\n")
    |> Enum.reduce([], fn line, acc ->
      trimmed = String.trim(line)

      cond do
        String.starts_with?(trimmed, "## ") ->
          [
            %{
              title: String.trim_leading(trimmed, "## "),
              domain: nil,
              narrative: [],
              assumptions: []
            }
            | acc
          ]

        acc == [] ->
          acc

        String.starts_with?(trimmed, "Domain:") ->
          [cur | rest] = acc
          [%{cur | domain: trimmed |> String.trim_leading("Domain:") |> String.trim()} | rest]

        String.starts_with?(trimmed, "- ") ->
          [cur | rest] = acc
          [%{cur | assumptions: cur.assumptions ++ [String.trim_leading(trimmed, "- ")]} | rest]

        true ->
          [cur | rest] = acc
          [%{cur | narrative: cur.narrative ++ [line]} | rest]
      end
    end)
    |> Enum.reverse()
    |> Enum.map(fn sc -> %{sc | narrative: sc.narrative |> Enum.join("\n") |> String.trim()} end)
  end

  # ------------------------------------------------------------------ export

  @doc "Writes a pack's rows to a folder in the import format."
  @spec export(String.t(), Path.t()) :: :ok | {:error, term()}
  def export(name, dir) do
    case get_pack(name) do
      nil -> {:error, :unknown_pack}
      pack -> write_folder(pack, dir)
    end
  end

  defp write_folder(pack, dir) do
    File.mkdir_p!(Path.join(dir, "knowledge"))
    name = pack.name

    write_json(dir, "pack.json", %{
      "name" => name,
      "title" => pack.title,
      "description" => pack.description
    })

    signals = Repo.all(from s in Signal, where: s.pack == ^name, order_by: s.name)
    {derived, raw} = Enum.split_with(signals, &(&1.kind == "derived"))
    write_json(dir, "signals.json", Enum.map(raw, &signal_json/1))

    write_json(
      dir,
      "derived.json",
      Enum.map(
        derived,
        &(&1
          |> signal_json()
          |> Map.drop(["kind", "source_spec"])
          |> Map.put("spec", Map.delete(&1.source_spec, "system")))
      )
    )

    write_facts(dir, name)

    write_json(
      dir,
      "templates.json",
      Repo.all(from t in QuestionTemplate, where: t.pack == ^name, order_by: t.key)
      |> Enum.map(
        &Map.take(
          &1,
          ~w(key domain title_pattern event_definition_pattern resolution_condition_pattern cadence window_length params starts_on active)a
        )
      )
    )

    write_json(
      dir,
      "models.json",
      Repo.all(from m in ModelVersion, where: m.pack == ^name, order_by: m.id, preload: :agent)
      |> Enum.map(
        &(Map.take(&1, ~w(model_module version domains params notes)a)
          |> Map.put(:agent, &1.agent.name))
      )
    )

    File.write!(Path.join(dir, "scenarios.md"), scenarios_md(name))
    :ok
  end

  defp signal_json(s),
    do:
      s
      |> Map.take(~w(name domain kind cadence units definition_notes source_spec)a)
      |> Map.new(fn {k, v} -> {to_string(k), v} end)

  defp write_facts(dir, name) do
    header = ~w(predicate subject object attributes valid_from valid_to domain note)

    rows =
      Knowledge.list_facts(pack: name)
      |> Enum.map(fn f ->
        [
          f.predicate,
          f.subject,
          f.object,
          if(f.attributes == %{}, do: "", else: Jason.encode!(f.attributes)),
          iso(f.valid_from),
          iso(f.valid_to),
          f.domain || "",
          f.note || ""
        ]
      end)

    File.write!(
      Path.join(dir, "knowledge/facts.csv"),
      NimbleCSV.RFC4180.dump_to_iodata([header | rows])
    )
  end

  defp scenarios_md(name) do
    Repo.all(
      from s in Scenario,
        where: s.pack == ^name,
        order_by: s.id,
        preload: [assumptions: ^from(a in Assumption, order_by: a.id)]
    )
    |> Enum.map_join("\n", fn s ->
      domain = if s.domain, do: "Domain: #{s.domain}\n\n", else: ""
      assumptions = Enum.map_join(s.assumptions, "", &"- #{&1.statement}\n")
      "## #{s.title}\n\n#{domain}#{s.narrative}\n\n#{assumptions}"
    end)
  end

  defp iso(nil), do: ""
  defp iso(dt), do: DateTime.to_iso8601(dt)

  defp write_json(dir, file, data),
    do: File.write!(Path.join(dir, file), Jason.encode_to_iodata!(data, pretty: true))

  # ----------------------------------------------------------------- helpers

  defp read_json(dir, file, default) do
    path = Path.join(dir, file)

    cond do
      File.exists?(path) ->
        case Jason.decode(File.read!(path)) do
          {:ok, data} -> {:ok, data}
          {:error, e} -> {:error, {:bad_json, file, Exception.message(e)}}
        end

      default == :required ->
        {:error, {:missing_file, path}}

      true ->
        {:ok, default}
    end
  end

  # Applies `fun` to each item; each returns {:ok, count} or {:error, reason}.
  defp each(items, fun) do
    Enum.reduce_while(items, {:ok, 0}, fn item, {:ok, n} ->
      case fun.(item) do
        {:ok, k} -> {:cont, {:ok, n + k}}
        {:error, %Ecto.Changeset{} = cs} -> {:halt, {:error, {:invalid, errors(cs)}}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp update_if_changed(_struct, %Ecto.Changeset{changes: changes}) when map_size(changes) == 0,
    do: {:ok, 0}

  defp update_if_changed(_struct, cs) do
    with {:ok, _} <- Repo.update(cs), do: {:ok, 1}
  end

  defp errors(cs), do: Ecto.Changeset.traverse_errors(cs, fn {msg, _} -> msg end)
end
