# 0020. MCP server: own stdio implementation, restricted query role, named agents

- Status: accepted
- Date: 2026-11-03

## Context

The prompt asks for an MCP (Model Context Protocol) server on the stdio transport, with a fixed tool list. The `query` tool must read only the `rules` schema. The prompt names no library. Tools that record who did something need an agent, and an MCP client knows names, not database ids.

## Decision

- **Own implementation.** We implement the protocol in `ForecastLoop.MCP.Server` without a dependency. It handles `initialize`, `ping`, `tools/list`, `tools/call` and notifications, with one JSON message on each line.
- **Clean stdout.** Logs go to stderr. The task replaces the default log handler after `app.start`, because the standard handler cannot change its device. The flake's `shellHook` writes to stderr. Run `mix compile` before you start the server, because Mix prints compiler output to stdout.
- **Validation.** Every tool has a JSON Schema. `ForecastLoop.MCP.Validate` checks the arguments against it before the tool acts. The changesets then check the domain rules again. `create_question` uses the FIP changeset (ADR 0006).
- **Extra tools.** `review_question`, `create_pack` and `export_pack` are added to the prompt's list. A question cannot go live without a review, and ADR 0009 puts the pack builder in MCP.
- **Restricted query.** `Rules.query/2` runs in a read-only transaction that it always rolls back. It sets a statement timeout, `search_path = rules`, and `SET LOCAL ROLE forecast_loop_rules_reader`. That role reads the rule views. It also reads `observations` and `batch_context`, because functions that the views call run with the caller's privileges. `priv/sql/grants.sql` grants the privileges again after each SQL reload.
- **Named agents.** A tool takes an agent name and makes the agent if it does not exist. The default kind is `llm` for forecasts and `human` for authors and reviewers.

## Consequences

The `query` tool can read the raw `observations` table as well as the rule views. The role needs a migration user that can create roles. On a managed database without that right, create the role by hand, then run the migration.
