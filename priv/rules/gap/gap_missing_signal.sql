-- A question in review or live whose condition cites a signal that does not exist or
-- has no as-of observations. For a series condition whose window started at least
-- 7 days before as_of, it is also a gap when no observation falls inside
-- [window_from, as_of]. (An events signal can correctly have no events in a window.)
CREATE VIEW rules.gap_missing_signal AS
WITH ctx AS (SELECT as_of FROM batch_context),
obs AS (SELECT o.signal_id, o.effective_at FROM ctx, observations_as_of(ctx.as_of) o),
checked AS (
  SELECT w.question_id, w.signal_id,
    CASE
      WHEN s.id IS NULL THEN 'signal_does_not_exist'
      WHEN NOT EXISTS (SELECT 1 FROM obs o WHERE o.signal_id = w.signal_id) THEN 'no_observations'
      WHEN w.condition_type = 'series'
       AND w.window_from <= ctx.as_of - interval '7 days'
       AND NOT EXISTS (SELECT 1 FROM obs o WHERE o.signal_id = w.signal_id
                         AND o.effective_at >= w.window_from AND o.effective_at <= ctx.as_of)
        THEN 'no_observations_in_window'
    END AS reason
  FROM rules.loop_question_window w
  CROSS JOIN ctx
  LEFT JOIN signals s ON s.id = w.signal_id
  WHERE w.status IN ('review', 'live')
)
SELECT question_id::text AS subject_id,
       jsonb_build_object('question_id', question_id, 'signal_id', signal_id, 'reason', reason) AS detail
FROM checked
WHERE reason IS NOT NULL;

COMMENT ON VIEW rules.gap_missing_signal IS
  'A question in review or live is a gap when its cited signal does not exist, has no observations, or (for a series) has none in its started window.';
