CREATE VIEW rules.gap_unknown_entity AS
SELECT e.entity AS subject_id,
       jsonb_build_object('entity', e.entity, 'attribute', min(e.attribute),
                          'signals', jsonb_agg(DISTINCT e.signal_name),
                          'observations', count(DISTINCT e.observation_id),
                          'first_seen', min(e.effective_at)) AS detail
FROM rules.k_event_entity e
WHERE NOT EXISTS (
  SELECT 1 FROM knowledge_facts f
  WHERE f.predicate IN ('entity_attr', 'entity_domain') AND f.subject = e.entity
)
GROUP BY e.entity;

COMMENT ON VIEW rules.gap_unknown_entity IS
  'An entity named by an observation is a gap when no entity_attr or entity_domain fact describes it.';
