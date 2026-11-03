# Build prompt: ForecastLoop

This is the specification that ForecastLoop is built from (revision 2, 2026-11-03: domain-neutral core with domain packs). ADR 0009 amends the "Domain packs" section: users build packs in the application, and folders are the import/export format. Choices that the prompt leaves open are ADRs in `docs/adr/`, indexed in `DECISIONS.md`.

---

Build **ForecastLoop**, a general-purpose computational-futurology application: a forecast ledger plus a model registry, driven by a rule layer expressed as SQL views, that runs the following loop as a nightly batch:

narrative exploration → model construction → probabilistic forecasting → Forecast Integrity Protocol validation → predictability-collapse detection → model revision → repeat.

**Attribution.** The framework this app implements — the Computational Predictability Hypothesis, the seven principles, the Forecast Integrity Protocol (FIP), predictability collapse as `H(Future) − H(Future | Present)`, and the loop above — is Peter Rothman's *Computational Futurology* (Lecturer in Computational Futurology, UC Santa Cruz; "Computational Futurology: Moving Beyond 20th-Century Foresight", LinkedIn, March 10, 2026, https://www.linkedin.com/pulse/computational-futurology-moving-beyond-20th-century-peter-rothman-gxonc/). Credit him in the `README.md` (a short "Background" section with the citation above), in the `@moduledoc` of the top-level `ForecastLoop` module, and in the UI footer. Use the terms "Forecast Integrity Protocol" and "predictability collapse" as he defines them; do not rename them. The app's design, code, and any errors in interpreting the framework are ours, not his — say so in the README.

**Scope.** The core is domain-neutral. It knows about questions, forecasts, signals, events, entities, and knowledge facts — not about incidents, deploys, revenue, elections, or anything else. Everything domain-specific lives in a **domain pack** (defined below). Ship two packs of different character to prove the core is general: `release_engineering` (software incidents and deploys) and `regional_economy` (public economic series for a US county or metro). Nothing in `lib/forecast_loop/` outside `lib/forecast_loop/packs/` may mention a pack's vocabulary. Enforce that with a test that greps the core for pack-specific words.

Work in phases. Finish each phase with passing tests and a short status note before starting the next. Ask me only when a decision cannot be undone and could reasonably go either way; otherwise choose sensibly and record the choice in `DECISIONS.md`.

## Stack (fixed)

- Elixir 1.20 on OTP 28, Phoenix 1.8.6, Phoenix LiveView 1.2, Ecto, PostgreSQL 18, Oban for scheduled jobs. Generate the project with the current `phx.new` (daisyUI/Tailwind scaffold is fine; keep the default layouts). Use Elixir 1.20's type checker: fix every type warning it emits rather than silencing it.
- Nix flake for the dev environment (`nix develop` gives Elixir, Erlang, and PostgreSQL 18).
- **All rules live in PostgreSQL as views** (see "Rule layer"). No Datalog engine, no RDF. Design so that a later port to Datalog is mechanical: one view per rule, no rule logic in Elixir or in LiveViews.
- Numerical work in **Nx** with EXLA. Use the provided `EDivisive` module (in `lib/e_divisive.ex`; copy it in unchanged and keep its tests passing).
- Expose the app to Claude through an **MCP server** (stdio transport) in `lib/forecast_loop/mcp/`.
- No LLM calls inside the nightly batch. LLM-assisted work happens only through the MCP server when a person is driving a session.

## Core objects (Ecto schemas; every table has `inserted_at`, `updated_at`, and an `asserted_by` provenance column)

**Ledger**

- `scenarios` — title, narrative text, domain, status.
- `assumptions` — scenario_id, statement, optional question_id.
- `questions` — title, event_definition (text), resolution_condition (JSONB; see below), deadline (utc datetime), domain (string), status (`draft|review|live|resolved|void`), created_by, reviewed_by, template_id (nullable).
- `question_templates` — domain, title pattern, event_definition pattern, resolution_condition pattern, cadence (`weekly|monthly|quarterly`), window length. The batch instantiates the next period's question from each active template so standing questions recur without hand entry.
- `agents` — name, kind (`human|model|llm`). Humans and models are scored identically.
- `model_versions` — agent_id, model_module, version, params (JSONB), domains (array), supersedes_id, notes.
- `forecasts` — question_id, agent_id, model_version_id (nullable), probability (0..1, float), rationale, cited_signal_ids (array), made_at. **Append-only**: a trigger rejects UPDATE and DELETE; a revision is a new row.
- `resolutions` — question_id, outcome (bool), resolved_at, source (text), evidence (JSONB), resolved_by.
- `scores` — forecast_id, brier, log_score, computed_at. Derived only; a materialization of `rules.cal_score`.

**Resolution conditions** (JSONB), one of:

- `{"type":"manual"}`
- `{"type":"series","signal_id":…,"op":">=|<=|>|<","value":…,"at":"end_of_window|any_in_window|mean_in_window","window":{"from":…,"to":…}}`
- `{"type":"events","signal_id":…,"op":"count>=|count<=","value":…,"window":{…},"where":{"<attribute>":<value or list>}}` where `<attribute>` may be a raw observation attribute or a **class** produced by the knowledge rules (`"class":"…"`).

**Signals and observations**

- `signals` — name, domain, kind (`series|events|derived`), source_spec (JSONB), units, cadence, coverage_start, coverage_end, definition_notes, pack (nullable).
- `observations` — signal_id, effective_at, observed_at, value (float, nullable), attributes (JSONB), source_record_id. Unique on (signal_id, source_record_id, observed_at). **Never overwrite**; a revised value is a new row with a later `observed_at`. Same no-UPDATE/DELETE trigger.
- `regime_shifts` — signal_id, effective_at, statistic, p_value, detector_version (JSONB), run_id.

**Knowledge** (hand-asserted facts the rules apply to raw data; the only place domain meaning enters the core)

- `knowledge_facts` — predicate (text), subject (text), object (text), attributes (JSONB), valid_from, valid_to (nullable), domain, pack (nullable), asserted_by, note.

The core defines exactly these predicates and the rules below interpret only these; packs supply rows, never new predicates:

| predicate | meaning | example subject → object |
|---|---|---|
| `value_alias` | normalize a raw attribute value | `severity:P0` → `sev1` (with `valid_to`) |
| `class_rule` | an event is in class *object* when attribute *subject* has the value in `attributes.equals` | `cause` → `release_related` with `{"equals":"deploy"}` |
| `link_rule` | events in signal A are linked to events in signal B that share entity attribute `attributes.on` and occurred within `attributes.within` (ISO duration) before; linked events gain class *object* | `incidents→deploys` → `release_related` with `{"on":"service","within":"PT24H"}` |
| `entity_alias` | two entity names are the same thing | `auth-api` → `identity` |
| `entity_attr` | an entity has an attribute | `auth-api` → `owner=release-eng`, `Ingham County` → `state=MI` |
| `entity_domain` | an entity belongs to a forecasting domain | `release-eng` → `release_engineering` |
| `same_as` | two signals measure the same thing | `fred:LAUCN260650000000003` → `bls:ingham_unemployment` |
| `min_history` | minimum classified events (or series points) a domain needs before base-rate models run | `release_engineering` → `20` |

Provide `mix forecast_loop.knowledge.import <path>` that loads CSVs idempotently (upsert on predicate+subject+object+valid_from).

**Batch bookkeeping**

- `work_items` — kind, subject_type, subject_id, payload (JSONB), status (`open|done|dismissed`), run_id. Unique on (kind, subject_type, subject_id) while open.
- `runs` — started_at, finished_at, as_of, status, stats (JSONB).
- `batch_context` — one row: `as_of`. Every rule view that reads observations reads this, so backtests get historical rule results from the same views.

**As-of access.** All reads of observations go through one function `Observations.as_of(signal_ids, t)` returning, per (signal_id, effective_at), the row with the latest `observed_at <= t`. One SQL query (`DISTINCT ON` or lateral join). Never reimplement it.

## Domain packs (`lib/forecast_loop/packs/<name>/` + `priv/packs/<name>/`)

A pack is data plus thin adapters, installed with `mix forecast_loop.pack.install <name>`:

- `knowledge/*.csv` — rows for the predicates above.
- `signals.json` — signal definitions with source specs.
- `derived.json` — derived series: name, SQL over `rules.k_*` views (e.g. weekly count of events in class X per entity), cadence.
- `templates.json` — question templates.
- `scenarios.md` — one or two starter scenarios with assumptions.
- `sources/` (optional) — `ForecastLoop.Sources.*` modules specific to the pack's systems.
- `README.md` — what the pack forecasts and what the knowledge facts mean.

Packs may add sources and knowledge rows. They may **not** add rule views, predicates, or schema. If a pack needs something the core can't express, that's a core change, recorded in `DECISIONS.md`.

**`release_engineering` pack**: signals `incidents` (incident.io), `deploys` (GitHub releases); `class_rule` and `link_rule` rows producing the `release_related` class; derived `release_incident_rate`; templates "≥1 sev1/sev2 release-related incident in <month>" and "release-related incidents per deploy in <quarter> below <x>".

**`regional_economy` pack**: public series for one county/metro — unemployment rate, labor force, building permits, new business registrations — via a generic `Sources.HTTPCSV` (URL + column mapping; FRED and state open-data portals both serve CSV). `entity_attr` rows for places; `same_as` rows where two publishers carry the same series; derived series such as 3-month change; templates "unemployment rate for <county> above <x> at end of <quarter>" and "building permits in <quarter> exceed same quarter prior year".

## Rule layer (PostgreSQL views, one logical rule per view)

Naming convention, enforced by a test over `pg_views` in the `rules` schema:

- `rules.k_<name>` — knowledge rules: normalize, classify, link. Pure classification; no probabilities, no rates.
- `rules.gap_<name>` — what the system needs but lacks; each row becomes a `gap` work item.
- `rules.loop_<name>` — the forecasting cycle.
- `rules.cal_<name>` — scoring and calibration.

Each view has `COMMENT ON VIEW` stating its rule in one sentence. SQL lives in `priv/rules/<group>/<name>.sql`; migrations read the files. No rule logic in Elixir or LiveViews.

**Knowledge rules (generic; interpret only the predicate table above)**

- `k_observation_normalized` — observations with `value_alias` applied to every attribute, using the alias valid at `effective_at`; entity names canonicalized through `entity_alias`.
- `k_event_class` — (observation_id, class, reason) for every `class_rule` whose attribute test matches, and for every `link_rule` that links it to an observation in the linked signal within the window on the shared entity. `reason` is the knowledge fact id.
- `k_event_entity` — (observation_id, entity) for every entity-valued attribute, canonicalized.
- `k_event_domain` — (observation_id, domain) via `k_event_entity` → `entity_domain`, falling back to the signal's domain.
- `k_series_canonical` — for `same_as` groups, one canonical series per group with the publisher priority from `attributes.priority`.

**Gap rules (generic)**

- `gap_unclassified_event` — events in a signal that has at least one `class_rule`/`link_rule`, where no rule fired and no attribute explicitly negates (per `attributes.negates` on the rule).
- `gap_unknown_entity` — entities in `k_event_entity` with no `entity_attr` and no `entity_domain`.
- `gap_unowned_domain` — domains referenced by questions with no `min_history` fact.
- `gap_missing_signal` — questions whose resolution condition cites a signal that does not exist or has no observations in the window.
- `gap_insufficient_history` — domains below their `min_history`.
- `gap_source_conflict` — `same_as` pairs whose values differ at the same `effective_at` beyond a tolerance in the fact's attributes.
- `gap_definition_change` — a signal whose latest refresh returned attribute keys or value types not seen in the prior 30 days.
- `gap_stale_source` — a signal with no new observation for longer than twice its cadence.

**Loop rules**

- `loop_underspecified_question`, `loop_live_question` (reviewer ≠ author), `loop_needs_forecast` (live question × model version covering its domain, no forecast yet), `loop_stale_forecast` (a cited signal moved past the configured threshold since the agent's last forecast), `loop_threshold_crossed` (series or events condition satisfied as-of), `loop_resolvable` (threshold crossed or deadline passed), `loop_template_due` (templates whose next period has no question yet), `loop_regime_shift_recent`, `loop_needs_revision` (models covering a collapsed domain), `loop_needs_rethink` (scenarios with a falsified assumption).

**Scoring and calibration rules**

- `cal_score` — Brier and log score per (forecast, resolution); clip to [0.01, 0.99] for log.
- `cal_bucket` — per (agent, domain, decile): n, mean probability, observed frequency.
- `cal_summary` — per (agent, domain): mean Brier, mean log, skill vs. base rate, Murphy decomposition (reliability, resolution, uncertainty).
- `cal_drift` — recent-window Brier exceeds baseline-window Brier by the configured margin.
- `cal_collapse_suspected` — `cal_drift` ∧ a recent `regime_shift` on a signal cited by any question in the domain.

## Nightly batch (Oban, one workflow, each step idempotent)

1. **Context**: insert the run; set `batch_context.as_of`.
2. **Refresh**: every non-derived signal through its source module; append. On error or shape change, `refresh_failed` / `definition_change` work item; no partial ingest.
3. **Knowledge snapshot**: export `rules.k_*` for this run to `priv/runs/<run_id>/` as CSV, so classification is reproducible after knowledge changes.
4. **Derive**: compute derived signals from `k_*` views; append.
5. **Changepoints**: `EDivisive.detect/2` on every series signal's as-of history; insert `regime_shifts`.
6. **Templates**: instantiate questions for `loop_template_due`, status `review` (a human still reviews before they go live).
7. **Gaps**: a `gap` work item per `gap_*` row not already open.
8. **Act**: resolve `loop_resolvable` with evidence; refresh `scores`; run models for `loop_needs_forecast`; open work items for stale/underspecified/revision/rethink.
9. **Record**.

`mix forecast_loop.run [--as-of DATE]`. Twice on identical data changes nothing but `runs`.

## Sources (`ForecastLoop.Sources` behaviour)

`fetch(spec, since_observed_at)` and `preview(spec)`. Core provides `Sources.Postgres`, `Sources.CSV` (file), `Sources.HTTPCSV` (URL + column map + optional date parsing), `Sources.Derived`. The `release_engineering` pack provides `Sources.IncidentIO` and `Sources.GitHubReleases`.

## Models (`ForecastLoop.Models` behaviour)

`forecast(model_version, question, as_of)`. Core provides:

- `Models.BaseRate` — frequency of the event over a trailing window of resolved questions from the same template, or of class-matching events.
- `Models.Poisson` — P(≥1 event in window) from an event-rate series.
- `Models.SeriesThreshold` — for series conditions: P(series ≥ x at end of window) from the empirical distribution of changes over the trailing window.

Models forecast under their own agent and are scored like anyone else. `mix forecast_loop.backtest --model <id> --from <date> --to <date>`.

## MCP server

Tools: `list_packs`, `install_pack`, `list_sources`, `preview_spec`, `register_signal`, `list_signals`, `list_knowledge`, `assert_knowledge`, `list_gaps`, `create_question`, `create_template`, `list_questions`, `submit_forecast`, `resolve_question`, `calibration_report`, `list_work_items`, `query` (read-only SQL against `rules`, statement timeout, returns SQL with rows). Refuses to create a question without all four FIP fields.

## LiveView UI (plain, functional)

- **Queue** — work items grouped by kind, gaps first; inline `assert_knowledge` for `gap_unknown_entity` and `gap_unclassified_event`.
- **Questions** — list by domain/status/due; detail with all agents' forecast history, resolution, evidence.
- **Forecast entry** — slider, rationale, cited signals.
- **Calibration** — per agent × domain: reliability diagram, Brier/log/skill, decomposition.
- **Signals** — catalog by domain, sparkline, regime shifts, definition changes, consuming views.
- **Knowledge** — facts by predicate/domain with validity ranges; inline edit.
- **Packs** — installed packs, what each contributed.
- **Runs** — history with step counts.

## Phases

1. Schemas, as-of query, append-only triggers, `batch_context`, seeds, tests.
2. Sources (Postgres, CSV, HTTPCSV, Derived), refresh, vintages, tests with revised rows.
3. Knowledge table, predicates, import task; `k_*` and `gap_*` views; gap work items; naming test; core-purity grep test.
4. `loop_*` views, templates, act step.
5. `cal_*` views, `scores`, calibration fixture test; Calibration LiveView.
6. `EDivisive`, `regime_shifts`, drift and collapse; fixture test.
7. Models, backtest, reproducibility test.
8. Pack mechanism and the `regional_economy` pack (no private APIs needed; test end to end on recorded CSVs).
9. `release_engineering` pack with its two sources, against recorded HTTP fixtures.
10. MCP server and remaining LiveViews.

## Acceptance

- Deleting a resolution and refreshing `scores` removes only its scores; re-adding reproduces them.
- Batch twice on the same data changes only `runs`.
- A backtest before a data revision uses the pre-revision value.
- A question cannot go live without a reviewer ≠ author.
- With the `regional_economy` pack alone installed, the full loop runs end to end on fixture CSVs: templates instantiate, a series question resolves, scores and calibration populate, a planted shift in the unemployment series produces a `regime_shift`.
- With the `release_engineering` pack: an event from an entity with no `entity_attr` opens `gap_unknown_entity`; asserting the fact closes it and the event is classified on the next run. Narrowing a `value_alias` `valid_to` reclassifies only events in the affected range.
- The core-purity test passes: no pack vocabulary outside `packs/`.
- Naming test passes; every rule view has a comment.
- `mix test`, `mix format --check-formatted`, `mix credo --strict`.

`README.md`: the loop, the four rule groups, the knowledge predicates, how to write a pack, how to add a source, model, or rule view, how to backtest. Keep `DECISIONS.md` current.
