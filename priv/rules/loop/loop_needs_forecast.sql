CREATE VIEW rules.loop_needs_forecast AS
SELECT q.id AS question_id, mv.id AS model_version_id, mv.agent_id, mv.model_module, q.domain
FROM questions q
JOIN model_versions mv ON q.domain = ANY (mv.domains)
WHERE q.status = 'live'
  AND NOT EXISTS (SELECT 1 FROM model_versions newer WHERE newer.supersedes_id = mv.id)
  AND NOT EXISTS (SELECT 1 FROM forecasts f WHERE f.question_id = q.id AND f.model_version_id = mv.id);

COMMENT ON VIEW rules.loop_needs_forecast IS
  'A live question needs a forecast from each current model version that covers its domain and has not forecast it yet.';
