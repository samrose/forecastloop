# ForecastLoop

ForecastLoop is a general-purpose forecasting application. It keeps a ledger of forecasting questions and probability forecasts, and a registry of forecasting models. Rules written as PostgreSQL views drive it. A nightly batch runs this loop:

> narrative exploration → model construction → probabilistic forecasting → Forecast Integrity Protocol validation → predictability-collapse detection → model revision → repeat

The core does not know any subject area. A **domain pack** gives it one: data sources, knowledge facts, question templates, models and scenarios. Two packs ship with it. `regional_economy` covers public economic series for Ingham County, Michigan. `release_engineering` covers software incidents and deploys.

## Background

The framework that ForecastLoop implements is Peter Rothman's *Computational Futurology*:

- the Computational Predictability Hypothesis
- the seven principles
- the **Forecast Integrity Protocol** (FIP)
- **predictability collapse**, defined as `H(Future) − H(Future | Present)`
- the loop above

Peter Rothman is Lecturer in Computational Futurology at UC Santa Cruz. Source: Peter Rothman, "Computational Futurology: Moving Beyond 20th-Century Foresight", LinkedIn, 10 March 2026, <https://www.linkedin.com/pulse/computational-futurology-moving-beyond-20th-century-peter-rothman-gxonc/>.

The design and the code of this application are ours, not his. Any errors in how the application interprets the framework are also ours. One example is the choice of the four FIP fields, described in [ADR 0006](docs/adr/0006-fip-fields.md).

## Quick start

The Nix flake (the file that pins the development tools) gives Elixir 1.20, Erlang/OTP 28 and PostgreSQL 18.

1. Enter the development shell: `nix develop`.
2. Start the local database cluster: `pg_ctl -l $PGDATA/log start`.
3. Get dependencies, create the database and load the seeds: `mix setup`.
4. Install a pack: `mix forecast_loop.pack.install regional_economy`.
5. Run the batch once: `mix forecast_loop.run`.
6. Start the web interface: `mix phx.server`, then open <http://localhost:4000>.
7. Run the checks: `mix test`, `mix format --check-formatted` and `mix credo --strict`.

The batch also runs every night at 02:00 UTC as an Oban job. Oban is the PostgreSQL-backed job queue.

## The loop

Each run of the batch has nine steps (`ForecastLoop.Batch.Runner`). Each step is idempotent: a second run on the same data changes only `runs`.

| Step | What it does | Loop stage |
| --- | --- | --- |
| 1. Context | Inserts the run and sets `batch_context.as_of`, the time that every rule view reads. | |
| 2. Refresh | Fetches every source signal and appends new or revised values. | |
| 3. Snapshot | Writes every `k_*` view to CSV in `priv/runs/<run_id>/`. | |
| 4. Derive | Computes derived series, such as quarterly sums or year-over-year changes. | |
| 5. Changepoints | Runs E-Divisive change-point detection and stores `regime_shifts`. | predictability-collapse detection |
| 6. Templates | Makes the next period's question from each question template. | narrative exploration |
| 7. Gaps | Opens a work item for each thing the system needs but lacks. | |
| 8. Act | Promotes reviewed questions, resolves questions, refreshes scores, runs models, and opens work items. | FIP validation, forecasting, model revision |
| 9. Record | Stores the counts of each step on the run. | |

**As-of data.** Observations are append-only. A revised value is a new row with a later `observed_at`, which is the time we learned it. Every read goes through one SQL function, `observations_as_of(t)`. It returns each record's latest value known at time `t`. So a backtest or a replay at a past date sees only what was known then.

## The rule layer

All rules are PostgreSQL views in the `rules` schema, with one rule in each view. Elixir code reads the views and acts on their rows, but it does not decide. Each view has a `COMMENT ON VIEW` that states its rule in one sentence. Each view's SQL is in its own file, `priv/rules/<group>/<name>.sql`. A test fails on any view that breaks the naming convention or has no comment.

| Group | Prefix | What its rules do | Examples |
| --- | --- | --- | --- |
| Knowledge | `k_` | Normalize, classify and link raw observations with the knowledge facts. These rules hold no probabilities and no rates. | `k_observation_normalized`, `k_event_class`, `k_event_domain` |
| Gaps | `gap_` | List what the system needs but does not have. Each row becomes a `gap` work item. | `gap_unknown_entity`, `gap_unclassified_event`, `gap_stale_source` |
| Loop | `loop_` | Run the forecasting cycle. | `loop_live_question`, `loop_resolvable`, `loop_stale_forecast`, `loop_template_due` |
| Calibration | `cal_` | Score forecasts and measure calibration and drift. | `cal_score`, `cal_summary`, `cal_drift`, `cal_collapse_suspected` |

`cal_collapse_suspected` is where predictability collapse becomes visible. It lists a domain when two things are true:

- Its forecasts score worse in the recent window than in the baseline window.
- A signal that the domain's questions cite had a recent regime shift.

## Knowledge predicates

Knowledge facts are the only place where domain meaning enters the core. A fact is `predicate(subject, object)`, valid from `valid_from` to `valid_to`. The core interprets exactly these eight predicates. A database constraint rejects any other predicate.

| Predicate | Meaning | Example |
| --- | --- | --- |
| `value_alias` | Normalize a raw attribute value. The subject is `"<attribute>:<value>"`. | `severity:P0` → `sev1` until 2026-03-01 |
| `class_rule` | An event is in class *object* when attribute *subject* has a value in `attributes.equals`. `attributes.negates` lists values that explicitly mean "not in this class". | `cause` → `release_related`, `{"equals": ["deploy"], "negates": ["hardware"]}` |
| `link_rule` | An event in signal A gets class *object* when an event in signal B names the same entity within `attributes.within` before it. | `incidents->deploys` → `release_related`, `{"on": ["service", "repo"], "within": "PT24H"}` |
| `entity_alias` | Two entity names are the same thing. | `acme/auth-service` → `auth-api` |
| `entity_attr` | An entity has an attribute. A value can name another entity. | `auth-api` → `owner=release-eng` |
| `entity_domain` | An entity belongs to a forecasting domain. | `release-eng` → `release_engineering` |
| `same_as` | Two signals measure the same thing. `attributes.priority` picks the canonical one. | `ingham_unemployment_rate` ↔ `ingham_unemployment_rate_bls` |
| `min_history` | The history that a domain needs before base-rate models run. | `regional_economy` → `24` |

To add a fact, use one of these:

- the Knowledge page
- the inline form on a gap in the Queue
- the MCP tool `assert_knowledge`
- a CSV file and `mix forecast_loop.knowledge.import <file or folder>`

The import is idempotent: a second import of the same file changes nothing.

## Domain packs

A pack is rows in the database that carry the pack's name in their `pack` column. You can build a pack in the application or import one from a folder ([ADR 0009](docs/adr/0009-packs-built-in-app.md)).

### Build a pack in the application

1. On the Packs page (or with the MCP tool `create_pack`), name the pack and say what it forecasts.
2. Add a signal from a generic source (`csv`, `http_csv` or `postgres`). Preview the rows first.
3. Run the batch. The gap rules then open work items for what the pack still needs, such as unknown entities or unclassified events. Answer each item in the Queue with a knowledge fact.
4. Add question templates and scenarios.
5. Export the pack to a folder to share it: `mix forecast_loop.pack.export <name> <folder>`.

### Pack folder format

Install a folder with `mix forecast_loop.pack.install <name or folder>`. A second install of the same folder changes nothing.

| File | Content |
| --- | --- |
| `pack.json` | `name`, `title`, `description`. This file is required. |
| `signals.json` | Signal definitions with their source specs. |
| `derived.json` | Derived series as declarative specs (`aggregate_by_period`, `change_over_periods`, `ratio`). |
| `knowledge/*.csv` | Knowledge facts. |
| `templates.json` | Question templates. Patterns use `{{period}}`, `{{period_start}}`, `{{period_end}}` and `{{param.x}}`. |
| `models.json` | Model versions that cover the pack's domains. |
| `scenarios.md` | `## Title` starts a scenario, `Domain: x` sets its domain, and `- statement` lines are assumptions. |
| `README.md` | What the pack forecasts and what its facts mean. |
| `vocabulary.txt` | The pack's words. The core-purity test fails if one of them appears in the core. |

A pack can add sources and rows. It cannot add rule views, predicates or schema. If a pack needs something that the core cannot express, change the core and record the change in an ADR.

## How to add a source

1. Write a module that implements the `ForecastLoop.Sources` behaviour. It needs `fetch(spec, since)`, `preview(spec)` and `describe()`.
2. Return rows with `source_record_id`, `effective_at`, `observed_at`, `value` and `attributes`.
3. Return `{:error, {:shape_changed, details}}` when the data no longer has the columns that the spec declares. The refresh step then opens a `definition_change` work item.
4. Register the module:
   - For a pack source, put it under `lib/forecast_loop/packs/<pack>/` and add `system/0`. The core finds it automatically.
   - For a core source, add it to `@core` in `ForecastLoop.Sources`.

Many tabular sources need no code. Use `http_csv` with a column map. A spec can also set these keys:

- `constant_attributes`: attributes added to every row
- `entity_attributes`: the attributes that hold entity names
- `publication_lag`: when a value without a publication date became known ([ADR 0018](docs/adr/0018-backfill-vintages-and-pack-data.md))

## How to add a model

1. Write a module that implements `ForecastLoop.Models`: `forecast(model_version, question, as_of)`.
2. Return `{:ok, probability, rationale, cited_signal_ids}`, or `{:error, :not_applicable}`.
3. Read observations only through `ForecastLoop.Observations.as_of/2` with the `as_of` you get.
4. Add the module to `config :forecast_loop, :models`.
5. Register a model version that names the module and the domains it covers.

The core models are `BaseRate`, `Poisson` and `SeriesThreshold`. A model forecasts under its own agent and is scored like any person.

## How to add a rule view

1. Write `priv/rules/<group>/<group>_<name>.sql`. It holds one `CREATE VIEW rules.<name>` and one `COMMENT ON VIEW` that states the rule in one sentence.
2. Read observations only through `observations_as_of((SELECT as_of FROM batch_context))`, or through a `k_*` view.
3. For a gap view, return `subject_id` and `detail` columns.
4. Add the file to `priv/rules/manifest.txt` after the views it reads.
5. Run `mix forecast_loop.sql.reload` while you develop.
6. Add a migration that calls `ForecastLoop.SQLFiles.reload_if_latest(__MODULE__, &execute/1)`, so that other databases get the view ([ADR 0011](docs/adr/0011-sql-files-loaded-by-newest-migration.md)).

## How to backtest

```
mix forecast_loop.backtest --model <model_version_id> --from 2025-01-01 --to 2026-06-30
```

The backtest replays the model on every resolved question whose deadline is in the range. It forecasts each question at its window start, with only the data known at that time, so it uses pre-revision values. It prints each forecast, the Brier and log scores, and the calibration buckets. It runs in a transaction that it rolls back, so it stores nothing. Add `--json` for machine-readable output.

To replay the whole batch at a past date, run `mix forecast_loop.run --as-of 2026-01-05 --no-refresh`.

## MCP server (for Claude)

The MCP (Model Context Protocol) server lets Claude use ForecastLoop through tools. No LLM call happens inside the nightly batch. A person drives every LLM session.

1. Compile first: `nix develop -c mix compile`. Mix prints compiler output to stdout, which an MCP client would read as a protocol message.
2. Add the server to Claude Code in `.mcp.json`:

```json
{"mcpServers": {"forecast_loop": {"command": "nix", "args": ["develop", "-c", "mix", "forecast_loop.mcp"]}}}
```

The tools are `list_packs`, `install_pack`, `create_pack`, `export_pack`, `list_sources`, `preview_spec`, `register_signal`, `list_signals`, `list_knowledge`, `assert_knowledge`, `list_gaps`, `create_question`, `review_question`, `create_template`, `list_questions`, `submit_forecast`, `resolve_question`, `calibration_report`, `list_work_items` and `query`.

- `create_question` refuses a question without all four FIP fields.
- `query` runs read-only SQL as a database role that can read only the rule views ([ADR 0020](docs/adr/0020-mcp-server.md)).

## Web interface

| Page | What it shows |
| --- | --- |
| Queue | Open work items, gaps first. An unknown entity or an unclassified event has an inline form to assert a fact. |
| Questions | Questions by domain, status and deadline. Each question shows all agents' forecast history, its resolution and evidence, a review form, and forecast entry (slider, rationale, cited signals). |
| Calibration | For each agent and domain: Brier, log score, skill, Murphy decomposition, and a reliability diagram. It also shows drift and suspected collapse. |
| Signals | The catalog by domain, with a sparkline, regime shifts, definition changes and consumers. |
| Knowledge | Facts by predicate and domain, with validity ranges and inline editing. |
| Packs | Installed packs and what each contributed, folders to install, and the pack builder. |
| Runs | Run history with step counts and each run's snapshot directory. |

## Known limits

- **`lib/e_divisive.ex` is our own implementation.** The prompt says that the module is provided, but we did not receive it ([ADR 0014](docs/adr/0014-own-edivisive-implementation.md)). Replace the file when you have the original.
- **The release_engineering fixtures are hand-written**, in the documented response shapes of incident.io and GitHub. Check the sources against a live account before you use them.
- **The regional_economy fixtures are real FRED downloads** from 2026-11-03. The publication lags in the pack are approximate. The permit series is state-level, because FRED has no monthly county series.
- **`batch_context` is one row for the whole database.** A batch run and a backtest wait for each other ([ADR 0016](docs/adr/0016-loop-resolution-and-batch-context.md)).

## Decisions

Every design decision is an ADR in [`docs/adr/`](docs/adr/). [`DECISIONS.md`](DECISIONS.md) is the index. The full specification is [`docs/BUILD_PROMPT.md`](docs/BUILD_PROMPT.md).
