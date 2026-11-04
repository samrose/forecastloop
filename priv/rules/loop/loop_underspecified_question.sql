CREATE VIEW rules.loop_underspecified_question AS
SELECT q.id::text AS subject_id,
       jsonb_build_object('question_id', q.id, 'title', q.title, 'status', q.status,
         'missing', to_jsonb(array_remove(ARRAY[
           CASE WHEN q.event_definition IS NULL OR q.event_definition = '' THEN 'event_definition' END,
           CASE WHEN q.resolution_condition IS NULL THEN 'resolution_condition' END,
           CASE WHEN q.deadline IS NULL THEN 'deadline' END,
           CASE WHEN q.domain IS NULL OR q.domain = '' THEN 'domain' END], NULL))) AS detail
FROM questions q
WHERE q.status IN ('draft', 'review')
  AND (q.event_definition IS NULL OR q.event_definition = '' OR q.resolution_condition IS NULL
       OR q.deadline IS NULL OR q.domain IS NULL OR q.domain = '');

COMMENT ON VIEW rules.loop_underspecified_question IS
  'A draft or review question is underspecified when it lacks a Forecast Integrity Protocol field (event definition, resolution condition, deadline or domain).';
