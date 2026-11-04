-- History of a domain = distinct as-of observations in the domain (rules.k_event_domain)
-- that are series or derived points, or classified events (rules.k_event_class).
CREATE VIEW rules.gap_insufficient_history AS
WITH history AS (
  SELECT d.domain, count(DISTINCT d.observation_id) AS n
  FROM rules.k_event_domain d
  JOIN rules.k_observation_normalized o ON o.observation_id = d.observation_id
  WHERE o.signal_kind IN ('series', 'derived')
     OR EXISTS (SELECT 1 FROM rules.k_event_class c WHERE c.observation_id = d.observation_id)
  GROUP BY d.domain
)
SELECT f.subject AS subject_id,
       jsonb_build_object('domain', f.subject, 'have', COALESCE(h.n, 0),
                          'need', f.object::int) AS detail
FROM knowledge_facts f
LEFT JOIN history h ON h.domain = f.subject
WHERE f.predicate = 'min_history'
  AND COALESCE(h.n, 0) < f.object::int;

COMMENT ON VIEW rules.gap_insufficient_history IS
  'A domain is a gap when it has fewer classified events and series points than its min_history fact requires.';
