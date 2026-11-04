# 0019. release_engineering pack: source discovery, negation beats links, fixtures

- Status: accepted
- Date: 2026-11-03

## Context

The `release_engineering` pack needs two pack-specific sources (incident.io and GitHub). The pack must not change the core to register them. Its test data also showed that a deploy shortly before an incident made the incident release-related, even when the incident's Cause field said "third-party".

## Decision

- **Source discovery.** `Sources.systems/0` finds every module under `ForecastLoop.Packs.*` that implements the `ForecastLoop.Sources` behaviour and the optional `system/0` callback. A pack adds a source by adding a module. Config can still add systems.
- **Negation beats a link.** In `k_event_class`, a `link_rule` gives no class when a valid `class_rule` for the same class lists one of the event's values in `attributes.negates`. A person's explicit judgement in a field wins over a timing heuristic.
- **incident.io.** `observed_at` is the incident's `updated_at`, so each update is a new vintage. Test and tutorial incidents are skipped. `since` becomes the `updated_at[gte]` filter.
- **GitHub releases.** `effective_at` and `observed_at` are both `published_at`. A release is public from that moment, and GitHub gives no update time for a release. An edit to a published release is not a new vintage.
- **Repositories and services.** The `entity_alias` fact maps a repository name to the service it deploys, for example `acme/auth-service` → `auth-api`. The link rule uses `on = ["service", "repo"]`.
- **Fixtures.** The HTTP fixtures are hand-written in the response shapes that incident.io and GitHub document. They are not recordings from a live account.

## Consequences

Before you use the pack with a live account, check the source modules against real API responses. The custom field names (`Affected services`, `Cause`) are spec settings.
