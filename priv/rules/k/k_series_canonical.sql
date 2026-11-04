-- Groups of signals that measure the same thing, from same_as facts (subject and
-- object are signal names; the relation is symmetric and transitive). Each group has
-- one canonical signal: the lowest attributes.priority (an object of signal name to
-- integer); without a priority, a fact's object ranks 1 and its subject 2.
-- Facts must be valid at batch_context.as_of.
CREATE VIEW rules.k_series_canonical AS
WITH RECURSIVE facts AS (
  SELECT f.* FROM knowledge_facts f, batch_context ctx
  WHERE f.predicate = 'same_as'
    AND (f.valid_from IS NULL OR f.valid_from <= ctx.as_of)
    AND (f.valid_to IS NULL OR ctx.as_of < f.valid_to)
),
edges AS (
  SELECT subject AS a, object AS b FROM facts
  UNION SELECT object, subject FROM facts
),
closure(member, other) AS (
  SELECT a, a FROM edges
  UNION
  SELECT c.member, e.b FROM closure c JOIN edges e ON e.a = c.other
),
priority AS (
  SELECT name, min(p) AS p FROM (
    SELECT kv.key AS name, kv.value::int AS p
    FROM facts, jsonb_each_text(COALESCE(facts.attributes -> 'priority', '{}'::jsonb)) kv
    UNION ALL SELECT object, 1 FROM facts
    UNION ALL SELECT subject, 2 FROM facts
  ) x GROUP BY name
),
grouped AS (
  SELECT member, min(other) AS group_key FROM closure GROUP BY member
),
ranked AS (
  SELECT g.member, g.group_key, p.p,
         first_value(g.member) OVER (PARTITION BY g.group_key ORDER BY p.p, g.member) AS canonical
  FROM grouped g JOIN priority p ON p.name = g.member
)
SELECT r.member AS signal_name, s.id AS signal_id, r.group_key, r.p AS priority,
       r.canonical AS canonical_signal_name, cs.id AS canonical_signal_id
FROM ranked r
LEFT JOIN signals s ON s.name = r.member
LEFT JOIN signals cs ON cs.name = r.canonical;

COMMENT ON VIEW rules.k_series_canonical IS
  'Signals joined by same_as facts form one group, and the member with the best priority is the group''s canonical series.';
