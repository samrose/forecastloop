defmodule ForecastLoop.Repo.Migrations.CoreSchema do
  use Ecto.Migration

  def up do
    execute "CREATE SCHEMA IF NOT EXISTS rules"

    # Rejects UPDATE and DELETE. Attached to append-only tables (forecasts, observations).
    execute """
    CREATE FUNCTION forbid_mutation() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      RAISE EXCEPTION '% on %.% is not permitted: the table is append-only',
        TG_OP, TG_TABLE_SCHEMA, TG_TABLE_NAME
        USING ERRCODE = 'restrict_violation';
    END;
    $$
    """

    # ---------------------------------------------------------------- ledger
    create table(:agents) do
      add :name, :text, null: false
      add :kind, :text, null: false
      add :asserted_by, :text, null: false
      timestamps()
    end

    create unique_index(:agents, [:name])
    create constraint(:agents, :kind_valid, check: "kind IN ('human','model','llm')")

    create table(:scenarios) do
      add :title, :text, null: false
      add :narrative, :text, null: false, default: ""
      add :domain, :text
      add :status, :text, null: false, default: "active"
      add :asserted_by, :text, null: false
      timestamps()
    end

    create constraint(:scenarios, :status_valid, check: "status IN ('draft','active','retired')")

    # A standing question. The batch makes one question for each period from it.
    # Patterns use {{placeholders}}; see docs/adr/0008.
    create table(:question_templates) do
      add :key, :text, null: false
      add :domain, :text, null: false
      add :title_pattern, :text, null: false
      add :event_definition_pattern, :text, null: false
      add :resolution_condition_pattern, :map, null: false
      add :cadence, :text, null: false
      add :window_length, :text, null: false
      add :params, :map, null: false, default: %{}
      add :starts_on, :date, null: false
      add :active, :boolean, null: false, default: true
      add :created_by_id, references(:agents, on_delete: :restrict), null: false
      add :pack, :text
      add :asserted_by, :text, null: false
      timestamps()
    end

    create unique_index(:question_templates, [:key])

    create constraint(:question_templates, :cadence_valid,
             check: "cadence IN ('weekly','monthly','quarterly')"
           )

    create table(:questions) do
      add :title, :text, null: false
      add :event_definition, :text
      add :resolution_condition, :map
      add :deadline, :utc_datetime_usec
      add :domain, :text
      add :status, :text, null: false, default: "draft"
      add :created_by_id, references(:agents, on_delete: :restrict), null: false
      add :reviewed_by_id, references(:agents, on_delete: :restrict)
      add :template_id, references(:question_templates, on_delete: :restrict)
      add :template_period, :text
      add :asserted_by, :text, null: false
      timestamps()
    end

    create unique_index(:questions, [:template_id, :template_period],
             where: "template_id IS NOT NULL"
           )

    create constraint(:questions, :template_period_present,
             check: "(template_id IS NULL) = (template_period IS NULL)"
           )

    create index(:questions, [:status])
    create index(:questions, [:domain])

    create constraint(:questions, :status_valid,
             check: "status IN ('draft','review','live','resolved','void')"
           )

    create constraint(:questions, :resolution_condition_shape,
             check: """
             resolution_condition IS NULL
             OR resolution_condition->>'type' = 'manual'
             OR COALESCE(resolution_condition->>'type' = 'series'
                 AND jsonb_typeof(resolution_condition->'signal_id') = 'number'
                 AND resolution_condition->>'op' IN ('>=','<=','>','<')
                 AND jsonb_typeof(resolution_condition->'value') = 'number'
                 AND resolution_condition->>'at' IN ('end_of_window','any_in_window','mean_in_window'), false)
             OR COALESCE(resolution_condition->>'type' = 'events'
                 AND jsonb_typeof(resolution_condition->'signal_id') = 'number'
                 AND resolution_condition->>'op' IN ('count>=','count<=')
                 AND jsonb_typeof(resolution_condition->'value') = 'number', false)
             """
           )

    # Forecast Integrity Protocol invariant: a live or resolved question has all four
    # FIP fields and a reviewer who is not its author. See docs/adr/0006.
    create constraint(:questions, :fip_before_live,
             check: """
             status NOT IN ('live','resolved')
             OR COALESCE(event_definition IS NOT NULL AND event_definition <> ''
                 AND resolution_condition IS NOT NULL
                 AND deadline IS NOT NULL
                 AND domain IS NOT NULL AND domain <> ''
                 AND reviewed_by_id IS NOT NULL
                 AND reviewed_by_id <> created_by_id, false)
             """
           )

    create table(:assumptions) do
      add :scenario_id, references(:scenarios, on_delete: :delete_all), null: false
      add :statement, :text, null: false
      add :question_id, references(:questions, on_delete: :nilify_all)
      add :asserted_by, :text, null: false
      timestamps()
    end

    create index(:assumptions, [:scenario_id])
    create index(:assumptions, [:question_id])

    create table(:model_versions) do
      add :agent_id, references(:agents, on_delete: :restrict), null: false
      add :model_module, :text, null: false
      add :version, :text, null: false
      add :params, :map, null: false, default: %{}
      add :domains, {:array, :text}, null: false, default: []
      add :supersedes_id, references(:model_versions, on_delete: :restrict)
      add :notes, :text
      add :asserted_by, :text, null: false
      timestamps()
    end

    create unique_index(:model_versions, [:agent_id, :version])

    create table(:forecasts) do
      add :question_id, references(:questions, on_delete: :restrict), null: false
      add :agent_id, references(:agents, on_delete: :restrict), null: false
      add :model_version_id, references(:model_versions, on_delete: :restrict)
      add :probability, :float, null: false
      add :rationale, :text, null: false, default: ""
      add :cited_signal_ids, {:array, :bigint}, null: false, default: []
      add :made_at, :utc_datetime_usec, null: false
      add :asserted_by, :text, null: false
      timestamps()
    end

    create index(:forecasts, [:question_id, :agent_id, :made_at])
    create index(:forecasts, [:model_version_id])

    create constraint(:forecasts, :probability_range,
             check: "probability >= 0 AND probability <= 1"
           )

    execute """
    CREATE TRIGGER forecasts_append_only BEFORE UPDATE OR DELETE ON forecasts
    FOR EACH ROW EXECUTE FUNCTION forbid_mutation()
    """

    create table(:resolutions) do
      add :question_id, references(:questions, on_delete: :restrict), null: false
      add :outcome, :boolean, null: false
      add :resolved_at, :utc_datetime_usec, null: false
      add :source, :text, null: false
      add :evidence, :map, null: false, default: %{}
      add :resolved_by, :text, null: false
      add :asserted_by, :text, null: false
      timestamps()
    end

    create unique_index(:resolutions, [:question_id])

    create table(:scores) do
      add :forecast_id, references(:forecasts, on_delete: :restrict), null: false
      add :brier, :float, null: false
      add :log_score, :float, null: false
      add :computed_at, :utc_datetime_usec, null: false
      add :asserted_by, :text, null: false
      timestamps()
    end

    create unique_index(:scores, [:forecast_id])

    # --------------------------------------------------------------- signals
    create table(:signals) do
      add :name, :text, null: false
      add :domain, :text
      add :kind, :text, null: false
      add :source_spec, :map, null: false, default: %{}
      add :units, :text
      add :cadence, :text
      add :coverage_start, :utc_datetime_usec
      add :coverage_end, :utc_datetime_usec
      add :definition_notes, :text
      add :pack, :text
      add :asserted_by, :text, null: false
      timestamps()
    end

    create unique_index(:signals, [:name])

    create constraint(:signals, :kind_valid, check: "kind IN ('series','events','derived')")

    create table(:observations) do
      add :signal_id, references(:signals, on_delete: :restrict), null: false
      add :effective_at, :utc_datetime_usec, null: false
      add :observed_at, :utc_datetime_usec, null: false
      add :value, :float
      add :attributes, :map, null: false, default: %{}
      add :source_record_id, :text, null: false
      add :asserted_by, :text, null: false
      timestamps()
    end

    create unique_index(:observations, [:signal_id, :source_record_id, :observed_at])
    create index(:observations, [:signal_id, :effective_at])

    execute """
    CREATE TRIGGER observations_append_only BEFORE UPDATE OR DELETE ON observations
    FOR EACH ROW EXECUTE FUNCTION forbid_mutation()
    """

    create table(:runs) do
      add :started_at, :utc_datetime_usec, null: false
      add :finished_at, :utc_datetime_usec
      add :as_of, :utc_datetime_usec, null: false
      add :status, :text, null: false, default: "running"
      add :stats, :map, null: false, default: %{}
      add :asserted_by, :text, null: false
      timestamps()
    end

    create constraint(:runs, :status_valid, check: "status IN ('running','succeeded','failed')")

    create table(:regime_shifts) do
      add :signal_id, references(:signals, on_delete: :restrict), null: false
      add :effective_at, :utc_datetime_usec, null: false
      add :statistic, :float, null: false
      add :p_value, :float, null: false
      add :detector_version, :map, null: false, default: %{}
      add :run_id, references(:runs, on_delete: :nilify_all)
      add :asserted_by, :text, null: false
      timestamps()
    end

    create unique_index(:regime_shifts, [:signal_id, :effective_at, :detector_version])

    # ----------------------------------------------------------------- packs
    # A domain pack: data that a user builds in the app or imports from a folder.
    # Rows it contributes carry its name in their `pack` column. See docs/adr/0009.
    create table(:packs) do
      add :name, :text, null: false
      add :title, :text, null: false
      add :description, :text, null: false, default: ""
      add :status, :text, null: false, default: "draft"
      add :origin, :text, null: false, default: "builder"
      add :asserted_by, :text, null: false
      timestamps()
    end

    create unique_index(:packs, [:name])
    create constraint(:packs, :name_format, check: "name ~ '^[a-z][a-z0-9_]*$'")
    create constraint(:packs, :status_valid, check: "status IN ('draft','active','archived')")
    create constraint(:packs, :origin_valid, check: "origin IN ('builder','import')")

    # ------------------------------------------------------------- knowledge
    create table(:knowledge_facts) do
      add :predicate, :text, null: false
      add :subject, :text, null: false
      add :object, :text, null: false
      add :attributes, :map, null: false, default: %{}
      add :valid_from, :utc_datetime_usec
      add :valid_to, :utc_datetime_usec
      add :domain, :text
      add :pack, :text
      add :asserted_by, :text, null: false
      add :note, :text
      timestamps()
    end

    # Identity of a fact for idempotent CSV import. NULLS NOT DISTINCT (PostgreSQL 15+)
    # makes two facts with a NULL valid_from count as the same fact.
    execute """
    CREATE UNIQUE INDEX knowledge_facts_identity
      ON knowledge_facts (predicate, subject, object, valid_from) NULLS NOT DISTINCT
    """

    create index(:knowledge_facts, [:predicate, :subject])

    # The core interprets exactly these predicates. Packs supply rows, never predicates.
    create constraint(:knowledge_facts, :predicate_known,
             check: """
             predicate IN ('value_alias','class_rule','link_rule','entity_alias',
                           'entity_attr','entity_domain','same_as','min_history')
             """
           )

    create constraint(:knowledge_facts, :valid_range,
             check: "valid_to IS NULL OR valid_from IS NULL OR valid_from < valid_to"
           )

    # ------------------------------------------------------ batch bookkeeping
    create table(:work_items) do
      add :kind, :text, null: false
      add :subject_type, :text, null: false
      add :subject_id, :text, null: false
      add :payload, :map, null: false, default: %{}
      add :status, :text, null: false, default: "open"
      add :run_id, references(:runs, on_delete: :nilify_all)
      add :asserted_by, :text, null: false
      timestamps()
    end

    create unique_index(:work_items, [:kind, :subject_type, :subject_id],
             where: "status = 'open'",
             name: :work_items_open_unique
           )

    create constraint(:work_items, :status_valid, check: "status IN ('open','done','dismissed')")

    # One-row table. Every rule view reads its as-of timestamp from here.
    create table(:batch_context, primary_key: false) do
      add :id, :boolean, primary_key: true, default: true
      add :as_of, :utc_datetime_usec, null: false
      add :run_id, references(:runs, on_delete: :nilify_all)
      add :asserted_by, :text, null: false
      timestamps()
    end

    create constraint(:batch_context, :single_row, check: "id")

    execute """
    INSERT INTO batch_context (id, as_of, asserted_by, inserted_at, updated_at)
    VALUES (true, now(), 'migration', now(), now())
    """

    # Tunable rule parameters (thresholds, windows), read by the rule views.
    create table(:config, primary_key: false) do
      add :key, :text, primary_key: true
      add :value, :map, null: false
      add :note, :text
      add :asserted_by, :text, null: false
      timestamps()
    end

    # The single definition of as-of access: for each (signal, source record), the
    # vintage with the latest observed_at <= t. See docs/adr/0005.
    execute """
    CREATE FUNCTION observations_as_of(t timestamptz)
    RETURNS SETOF observations LANGUAGE sql STABLE AS $$
      SELECT DISTINCT ON (o.signal_id, o.source_record_id) o.*
      FROM observations o
      WHERE o.observed_at <= t
      ORDER BY o.signal_id, o.source_record_id, o.observed_at DESC, o.id DESC
    $$
    """
  end

  def down do
    execute "DROP FUNCTION IF EXISTS observations_as_of(timestamptz)"

    for t <-
          ~w(config batch_context work_items knowledge_facts packs regime_shifts runs observations signals scores resolutions forecasts model_versions assumptions questions question_templates scenarios agents) do
      execute "DROP TABLE IF EXISTS #{t} CASCADE"
    end

    execute "DROP FUNCTION IF EXISTS forbid_mutation()"
    execute "DROP SCHEMA IF EXISTS rules CASCADE"
  end
end
