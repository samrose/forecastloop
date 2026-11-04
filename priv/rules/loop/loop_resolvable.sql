-- A live question is resolvable when its condition is crossed, its outcome is
-- already determined, or its deadline has passed. `outcome` is NULL when a person
-- must decide: a manual condition, or data that is not yet complete.
CREATE VIEW rules.loop_resolvable AS
SELECT q.id AS question_id,
       CASE WHEN cs.satisfied THEN true WHEN cs.determined THEN cs.outcome END AS outcome,
       CASE
         WHEN cs.satisfied THEN 'threshold_crossed'
         WHEN cs.determined THEN 'condition_determined'
         WHEN q.resolution_condition ->> 'type' = 'manual' THEN 'manual'
         ELSE 'awaiting_data'
       END AS reason,
       COALESCE(cs.evidence, '{}'::jsonb) AS evidence
FROM questions q
CROSS JOIN batch_context ctx
LEFT JOIN rules.loop_condition_status cs ON cs.question_id = q.id
WHERE q.status = 'live'
  AND (COALESCE(cs.satisfied, false) OR COALESCE(cs.determined, false) OR q.deadline <= ctx.as_of);

COMMENT ON VIEW rules.loop_resolvable IS
  'A live question is resolvable when its condition is crossed or determined, or its deadline has passed.';
