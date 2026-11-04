CREATE VIEW rules.loop_live_question AS
SELECT q.id AS question_id, q.created_by_id, q.reviewed_by_id
FROM questions q
WHERE q.status = 'review'
  AND q.event_definition IS NOT NULL AND q.event_definition <> ''
  AND q.resolution_condition IS NOT NULL
  AND q.deadline IS NOT NULL
  AND q.domain IS NOT NULL AND q.domain <> ''
  AND q.reviewed_by_id IS NOT NULL
  AND q.reviewed_by_id <> q.created_by_id;

COMMENT ON VIEW rules.loop_live_question IS
  'A question in review goes live when it has all four Forecast Integrity Protocol fields and a reviewer who is not its author.';
