# Scenarios

## Safer releases after progressive delivery

Domain: release_engineering

The team moves auth-api and web-frontend to progressive delivery with automatic rollback. Deploy
frequency stays the same, but fewer deploys cause customer-facing incidents.

- Release-related incidents per deploy fall below 0.25 in each quarter.
- No month has more than one sev1 or sev2 release-related incident.

## Deploy freeze pressure

Domain: release_engineering

A run of release-related incidents leads to a deploy freeze. Fewer, larger releases follow, and each
release carries more risk.

- Deploys per quarter fall by a third.
- Release-related incidents per deploy rise above 0.5.
