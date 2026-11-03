# 0002. Stack version constraints

- Status: accepted
- Date: 2026-11-03

## Context

The prompt fixes Elixir 1.20, OTP 28, Phoenix 1.8.6, LiveView 1.2 and PostgreSQL 18. On 2026-11-03, nixpkgs-unstable gives Elixir 1.20.5, Erlang/OTP 28.5 and PostgreSQL 18.6. `phx.new` 1.8.6 writes the constraint `{:phoenix, "~> 1.8.6"}`, which means "1.8.6 or a later 1.8.x". It also writes `{:phoenix_live_view, "~> 1.1.0"}`, which excludes LiveView 1.2.

## Decision

- We generate the project with `phx_new` 1.8.6.
- We keep the generated constraint `~> 1.8.6` for Phoenix. Hex resolves it to 1.8.16, which has the same API and later bug fixes.
- We change the LiveView constraint to `~> 1.2` (resolves to 1.2.x).
- The flake pins nixpkgs through `flake.lock`. It uses `beam28Packages.elixir_1_20` and `postgresql_18`.

## Consequences

`mix deps.update phoenix` can move to a later 1.8.x patch release. To pin Phoenix to exactly 1.8.6, change the constraint to `== 1.8.6`.
