# 0009. Users build domain packs in the application

- Status: accepted (amends `docs/BUILD_PROMPT.md`, "Domain packs", phases 8 and 10, and the MCP tool list)
- Date: 2026-11-03

## Context

The prompt defines a domain pack as a repository folder that a developer writes and installs with a mix task. The project owner wants users to build packs in the application, guided by questions, without hand-written files or code.

## Decision

- A pack is data in the database. A `packs` table holds its name, description and status. Every row that a pack contributes (signals, knowledge facts, templates, scenarios, derived-series definitions) carries the pack name in its `pack` column.
- A guided builder, in the LiveView UI and as MCP tools, makes a pack in steps:
  1. Name the pack and state what it forecasts.
  2. Add a signal from a generic source (`Sources.CSV`, `Sources.HTTPCSV`, `Sources.Postgres`) and preview it.
  3. Answer the gap-rule work items (unknown entity, unclassified event, missing history). Each answer is a knowledge fact.
  4. Add question templates and starter scenarios.
- A user-built pack uses only generic sources. A pack that needs a bespoke API source (for example `release_engineering`) still ships an Elixir module.
- A derived series is a declarative spec, not free SQL. The core supports a fixed set of operations (for example: count events in a class for each entity for each period; change over N periods; ratio of two series). One core SQL view evaluates each operation.
- The folder layout of the prompt becomes the import/export format. `mix forecast_loop.pack.install <name>` imports a folder. An export task writes one. The two shipped packs load through import, the same path as any other pack.

## Consequences

- New MCP tools: `create_pack`, `export_pack`, and builder steps that reuse `register_signal`, `assert_knowledge` and `create_template`.
- `derived.json` holds declarative specs instead of SQL. A new derived operation is a core change and needs an ADR.
- The core-purity test must also check that pack names in the core appear only as data.
