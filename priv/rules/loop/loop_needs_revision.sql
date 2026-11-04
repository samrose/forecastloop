CREATE VIEW rules.loop_needs_revision AS
SELECT mv.id::text AS subject_id,
       jsonb_build_object('model_version_id', mv.id, 'version', mv.version,
         'model_module', mv.model_module, 'domains', jsonb_agg(c.domain ORDER BY c.domain)) AS detail
FROM model_versions mv
JOIN rules.cal_collapse_suspected c ON c.domain = ANY (mv.domains)
WHERE NOT EXISTS (SELECT 1 FROM model_versions newer WHERE newer.supersedes_id = mv.id)
GROUP BY mv.id, mv.version, mv.model_module;

COMMENT ON VIEW rules.loop_needs_revision IS
  'A current model version needs revision when it covers a domain where predictability collapse is suspected.';
