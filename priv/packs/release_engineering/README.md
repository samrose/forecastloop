# Pack: release_engineering

This pack forecasts software incidents and their relation to deploys. It is the events-shaped counterpart of `regional_economy`.

## Signals and sources

| Signal | Source module | What it holds |
| --- | --- | --- |
| `incidents` | `Packs.ReleaseEngineering.Sources.IncidentIO` (`incident_io`) | One event per incident.io incident. Each update is a new vintage. |
| `deploys` | `Packs.ReleaseEngineering.Sources.GitHubReleases` (`github_releases`) | One event per published GitHub release of the listed repositories. |

Set `INCIDENT_IO_API_KEY` (and `GITHUB_TOKEN` for private repositories) in the environment of the batch. Edit `repos` in `signals.json` for your repositories, and edit `custom_fields` for the names of your incident.io custom fields.

## Knowledge facts

| Fact | Meaning |
| --- | --- |
| `value_alias` `severity:P0` → `sev1` (to 2026-03-01) | The old P-scale maps to sev1–sev3 until the switch to incident.io severities. Narrowing `valid_to` reclassifies only the incidents in the changed date range. |
| `value_alias` `severity:SEV1` → `sev1` | incident.io severity names. |
| `class_rule` `cause` → `release_related` | An incident whose Cause is `deploy` or `config change` is release-related. `hardware`, `third-party` and `capacity` explicitly negate it. |
| `link_rule` `incidents->deploys` → `release_related` | An incident is release-related when a deploy to an affected service happened in the 24 hours before it. `on` = `["service", "repo"]`. |
| `entity_alias` `acme/auth-service` → `auth-api` | The repository is the deploy name of the service. This lets the link rule match a deploy to an incident's service. |
| `entity_attr` `auth-api` → `owner=release-eng` | Service ownership. |
| `entity_domain` `release-eng` → `release_engineering` | Services owned by release-eng belong to this domain. |
| `min_history` | 20 classified incidents before base-rate models run. |

A service or repository with no `entity_attr` or `entity_domain` opens a `gap_unknown_entity` work item. An incident that no rule classifies or negates opens `gap_unclassified_event`.

## Derived series and templates

- `release_incident_rate`: weekly release-related incidents. The Poisson model can use it as `rate_signal`.
- `release_incidents_per_deploy_quarterly`: release-related incidents / deploys, for each quarter.
- Template `sev12_release_incident_month`: "At least one sev1 or sev2 release-related incident in the month?"
- Template `release_incidents_per_deploy_below`: "Release-related incidents per deploy in the quarter below 0.25?"

## Fixtures

`fixtures/` holds hand-written JSON in the response shapes that incident.io (`GET /v2/incidents`) and GitHub (`GET /repos/{repo}/releases`) document. These files are not recordings from a live account. Check the source modules against your real API responses before you rely on them.
