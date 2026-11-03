# 0004. Domain-neutral core; domain content only in packs

- Status: accepted
- Date: 2026-11-03

## Context

The first build prompt put one domain (software incidents and deploys) into the core rule views. The project owner said the application must not be limited to that domain. Revision 2 of the prompt (`docs/BUILD_PROMPT.md`) makes the core domain-neutral. A domain pack (data and thin adapters for one subject area) supplies all domain meaning.

## Decision

- The core knows only questions, forecasts, signals, events, entities and knowledge facts.
- Domain meaning enters the core only as rows of `knowledge_facts`, which use eight fixed predicates.
- A CHECK constraint `knowledge_facts.predicate_known` rejects any other predicate, so a pack cannot add one.
- A test greps `lib/forecast_loop/` (except `packs/`), `priv/rules/` and `priv/repo/migrations/` for pack vocabulary.

## Consequences

To add a predicate, change the core: edit the constraint and the `Knowledge.Fact.predicates/0` list, and write a new ADR. The grep test needs its word list updated when a pack is added.
