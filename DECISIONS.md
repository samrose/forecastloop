# Decisions

Each design decision is an ADR (Architecture Decision Record) in [`docs/adr/`](docs/adr/). This file is the index. To add a decision, copy [`docs/adr/0000-template.md`](docs/adr/0000-template.md) to the next number and add one line here.

| ADR | Decision |
| --- | --- |
| [0001](docs/adr/0001-record-decisions-as-adrs.md) | Record decisions as ADRs; this file is the index. |
| [0002](docs/adr/0002-stack-version-constraints.md) | Phoenix `~> 1.8.6` (floor 1.8.6), LiveView `~> 1.2`, toolchain from nixpkgs. |
| [0003](docs/adr/0003-pin-fine-for-exla.md) | Pin `fine` 0.1.x because `fine` 0.2.0 breaks the EXLA 1.0.0 build. |
| [0004](docs/adr/0004-domain-neutral-core-and-packs.md) | Domain-neutral core; domain meaning only as knowledge rows from packs; predicate list enforced in the database. |
| [0005](docs/adr/0005-as-of-identity-is-source-record.md) | As-of access is keyed by `(signal_id, source_record_id)`, defined once as SQL function `observations_as_of`. |
| [0006](docs/adr/0006-fip-fields.md) | The four FIP fields are event definition, resolution condition, deadline and domain (our interpretation). |
| [0007](docs/adr/0007-fip-invariant-as-constraint.md) | A CHECK constraint guards the "live" invariant; the `loop_live_question` view drives promotion. |
| [0008](docs/adr/0008-question-templates.md) | Template placeholders, period labels, ISO durations and the `(template_id, template_period)` uniqueness key. |
| [0009](docs/adr/0009-packs-built-in-app.md) | Users build packs in the app (database rows, guided builder in UI and MCP); folders are the import/export format; derived series are declarative. |
