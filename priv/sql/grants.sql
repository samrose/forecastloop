-- Privileges of forecast_loop_rules_reader, the role that the MCP `query` tool and the
-- UI query box switch to (docs/adr/0020). It reads the rule views. Views read their
-- tables with the view owner's privileges, but functions run with the caller's, so the
-- role also reads `observations` (observations_as_of) and `batch_context`.
GRANT USAGE ON SCHEMA rules, fl, derive TO forecast_loop_rules_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA rules TO forecast_loop_rules_reader;
GRANT SELECT ON observations, batch_context TO forecast_loop_rules_reader;
