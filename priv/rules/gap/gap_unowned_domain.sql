CREATE VIEW rules.gap_unowned_domain AS
SELECT q.domain AS subject_id,
       jsonb_build_object('domain', q.domain, 'questions', count(*)) AS detail
FROM questions q
WHERE q.domain IS NOT NULL AND q.status <> 'void'
  AND NOT EXISTS (
    SELECT 1 FROM knowledge_facts f WHERE f.predicate = 'min_history' AND f.subject = q.domain
  )
GROUP BY q.domain;

COMMENT ON VIEW rules.gap_unowned_domain IS
  'A domain that questions use is a gap when no min_history fact states how much history it needs.';
