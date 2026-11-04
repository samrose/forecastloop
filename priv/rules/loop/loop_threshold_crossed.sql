CREATE VIEW rules.loop_threshold_crossed AS
SELECT question_id, signal_id, statistic, evidence
FROM rules.loop_condition_status
WHERE satisfied;

COMMENT ON VIEW rules.loop_threshold_crossed IS
  'A question''s series or events condition is crossed when the as-of observations in its window satisfy it.';
