# Decisions

Each design decision is an ADR (Architecture Decision Record) in [`docs/adr/`](docs/adr/). This file is the index. To add a decision, copy [`docs/adr/0000-template.md`](docs/adr/0000-template.md) to the next number and add one line here.

| ADR | Decision |
| --- | --- |
| [0001](docs/adr/0001-record-decisions-as-adrs.md) | Record each decision as an ADR. This file is the index. |
| [0002](docs/adr/0002-stack-version-constraints.md) | Phoenix `~> 1.8.6` (floor 1.8.6), LiveView `~> 1.2`, toolchain from nixpkgs. |
| [0003](docs/adr/0003-pin-fine-for-exla.md) | Pin `fine` 0.1.x because `fine` 0.2.0 breaks the EXLA 1.0.0 build. |
| [0004](docs/adr/0004-domain-neutral-core-and-packs.md) | A domain-neutral core. Domain meaning enters only as knowledge rows from packs, and the database enforces the predicate list. |
| [0005](docs/adr/0005-as-of-identity-is-source-record.md) | As-of access is keyed by `(signal_id, source_record_id)`, defined once as SQL function `observations_as_of`. |
| [0006](docs/adr/0006-fip-fields.md) | The four FIP fields are event definition, resolution condition, deadline and domain (our interpretation). |
| [0007](docs/adr/0007-fip-invariant-as-constraint.md) | A CHECK constraint guards the "live" invariant, and the `loop_live_question` view drives promotion. |
| [0008](docs/adr/0008-question-templates.md) | Template placeholders, period labels, ISO durations and the `(template_id, template_period)` uniqueness key. |
| [0009](docs/adr/0009-packs-built-in-app.md) | Users build packs in the app (database rows, a guided builder in the UI and MCP). Folders are the import/export format. Derived series are declarative. |
| [0010](docs/adr/0010-refresh-vintages-and-shape.md) | Refresh appends a vintage only when it is newer and different. A missing declared column is a shape change. Each signal ingests in one transaction. |
| [0011](docs/adr/0011-sql-files-loaded-by-newest-migration.md) | A manifest lists the SQL files. Only the newest migration loads them, so a fresh database loads them against the final schema. |
| [0012](docs/adr/0012-knowledge-rule-semantics.md) | How the k_/gap_ rules read the predicates: declared entity attributes, negation, link attribute pairs, same_as priority, gap work-item keys. |
| [0013](docs/adr/0013-scoring-and-calibration.md) | Log score sign and clipping, final-forecast calibration, Brier skill score, Murphy decomposition over deciles. |
| [0014](docs/adr/0014-own-edivisive-implementation.md) | Our own E-Divisive implementation, because the provided module was not supplied. The default sig_level is 0.01. |
| [0015](docs/adr/0015-timestamptz.md) | All application timestamps are timestamptz in UTC, and sessions run in UTC. |
| [0016](docs/adr/0016-loop-resolution-and-batch-context.md) | When an outcome is known, needs_resolution instead of guessing, stale-forecast range, and the shared batch_context lock. |
| [0017](docs/adr/0017-models-and-backtest.md) | The model return contract and registry. The backtest forecasts at window start in a rolled-back transaction. |
| [0018](docs/adr/0018-backfill-vintages-and-pack-data.md) | publication_lag for backfills, sum/mean period completeness, constant attributes, pack columns on scenarios and model versions, change-point max_points. |
| [0019](docs/adr/0019-release-engineering-pack.md) | Pack sources are found by module. An explicit class_rule negation beats a link_rule. Vintage rules for incident.io and GitHub. The fixtures are hand-written. |
| [0020](docs/adr/0020-mcp-server.md) | Own stdio MCP server with logs on stderr, schema validation, extra review/pack tools, a restricted role for the query tool, and named agents. |
| [0021](docs/adr/0021-apache-2-license.md) | The project uses the Apache License 2.0. |
| [0022](docs/adr/0022-plain-language-question-page.md) | The question page writes its condition, result and evidence in plain language, with the Brier score and the input values. |
