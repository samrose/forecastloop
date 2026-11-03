# 0011. SQL files are loaded by the newest migration only

- Status: accepted
- Date: 2026-11-03

## Context

The prompt keeps each rule view's SQL in its own file (`priv/rules/<group>/<name>.sql`) and asks migrations to read the files, so that a change to a rule shows as a diff of one file. But a migration that reads a file reads the file's current content, not the content it had when the migration was written. On a fresh database, an early migration would then load a view that refers to columns that only a later migration creates, and the migration would fail.

## Decision

- `priv/rules/manifest.txt` lists every SQL file in load order. The list includes helper functions (`priv/sql/functions/`, schema `fl`) and derived-series operations (`priv/sql/derive/`, schema `derive`).
- `ForecastLoop.SQLFiles.reload!/1` drops the `fl`, `derive` and `rules` schemas and recreates them from the manifest.
- A migration that changes SQL files calls `SQLFiles.reload_if_latest(__MODULE__, &execute/1)`. The call runs only when that migration is the newest file in `priv/repo/migrations/`. Older migrations skip the reload, so a fresh database loads the files once, against the final table schema.
- `down` drops the three schemas. After a rollback, run `mix forecast_loop.sql.reload` to load the files again.
- `mix forecast_loop.sql.reload` reloads the files during development.

## Consequences

- To change a rule, edit its file and add a new migration that calls `reload_if_latest`. The diff shows the rule change.
- Tables in `public` must not depend on objects in `fl`, `derive` or `rules`, because a reload drops those schemas with CASCADE.
