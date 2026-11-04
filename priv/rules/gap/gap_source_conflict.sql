-- For each same_as fact (signal names), the as-of observations of the two signals
-- at the same effective_at whose values differ by more than attributes.tolerance
-- (absolute; default 0).
CREATE VIEW rules.gap_source_conflict AS
WITH ctx AS (SELECT as_of FROM batch_context),
obs AS (SELECT o.* FROM ctx, observations_as_of(ctx.as_of) o),
pairs AS (
  SELECT f.id AS fact_id, f.subject, f.object,
         COALESCE((f.attributes ->> 'tolerance')::double precision, 0) AS tolerance,
         sa.id AS a_id, sb.id AS b_id
  FROM knowledge_facts f
  JOIN signals sa ON sa.name = f.subject
  JOIN signals sb ON sb.name = f.object
  WHERE f.predicate = 'same_as'
),
conflicts AS (
  SELECT p.fact_id, p.subject, p.object, p.tolerance, a.effective_at, a.value AS a_value, b.value AS b_value
  FROM pairs p
  JOIN obs a ON a.signal_id = p.a_id
  JOIN obs b ON b.signal_id = p.b_id AND b.effective_at = a.effective_at
  WHERE abs(a.value - b.value) > p.tolerance
)
SELECT fact_id::text AS subject_id,
       jsonb_build_object('same_as', subject || ' = ' || object, 'tolerance', tolerance,
         'conflicts', count(*),
         'examples', (jsonb_agg(jsonb_build_object('effective_at', effective_at,
                        subject, a_value, object, b_value) ORDER BY effective_at DESC)
                      -> 0)) AS detail
FROM conflicts
GROUP BY fact_id, subject, object, tolerance;

COMMENT ON VIEW rules.gap_source_conflict IS
  'Two signals declared same_as are a gap when their values at the same effective_at differ by more than the fact''s tolerance.';
