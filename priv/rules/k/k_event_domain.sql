-- Forecasting domains of observations. Start from each entity the observation names
-- and follow entity_attr facts ("key=value": value is another entity) up to 4 steps.
-- Every reached entity with an entity_domain fact gives a domain. An observation with
-- no such domain falls back to its signal's domain. Facts must be valid at effective_at.
CREATE VIEW rules.k_event_domain AS
WITH RECURSIVE reach(observation_id, effective_at, entity, depth) AS (
  SELECT observation_id, effective_at, entity, 0 FROM rules.k_event_entity
  UNION
  SELECT r.observation_id, r.effective_at, split_part(f.object, '=', 2), r.depth + 1
  FROM reach r
  JOIN knowledge_facts f
    ON f.predicate = 'entity_attr' AND f.subject = r.entity AND f.object LIKE '%=%'
   AND (f.valid_from IS NULL OR f.valid_from <= r.effective_at)
   AND (f.valid_to IS NULL OR r.effective_at < f.valid_to)
  WHERE r.depth < 4
),
by_entity AS (
  SELECT DISTINCT r.observation_id, f.object AS domain, r.entity AS via_entity
  FROM reach r
  JOIN knowledge_facts f
    ON f.predicate = 'entity_domain' AND f.subject = r.entity
   AND (f.valid_from IS NULL OR f.valid_from <= r.effective_at)
   AND (f.valid_to IS NULL OR r.effective_at < f.valid_to)
)
SELECT observation_id, domain, via_entity FROM by_entity
UNION ALL
SELECT n.observation_id, n.signal_domain, NULL
FROM rules.k_observation_normalized n
WHERE n.signal_domain IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM by_entity b WHERE b.observation_id = n.observation_id);

COMMENT ON VIEW rules.k_event_domain IS
  'An observation belongs to the entity_domain of any entity it names or reaches through entity_attr facts, and otherwise to its signal''s domain.';
