# 0015. All timestamps are timestamptz in UTC

- Status: accepted
- Date: 2026-11-03

## Context

The Ecto field type `:utc_datetime_usec` makes `timestamp without time zone` columns by default. The rule views compare these columns with `timestamptz` values, such as `batch_context.as_of` and the argument of `observations_as_of`. PostgreSQL converts between the two types with the session time zone. On a server that is not set to UTC, every as-of comparison would shift by the offset. The tests passed only because the development server used `Etc/UTC`.

## Decision

- Migration `20261103000005_timestamptz` changes every application timestamp column to `timestamptz`. It reads the stored values as UTC.
- New migrations make `timestamptz` columns (`migration_timestamps: [type: :timestamptz]`).
- The repo sets `timezone = UTC` for each session.
- Oban's own tables stay as Oban makes them.

## Consequences

As-of results do not depend on the server time zone.
