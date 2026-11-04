-- The resolution window and condition fields of every question with a series or
-- events condition. A missing window.from means the question's creation time; a
-- missing window.to means its deadline.
CREATE VIEW rules.loop_question_window AS
SELECT q.id AS question_id, q.domain, q.status, q.deadline, q.template_id,
       q.resolution_condition ->> 'type' AS condition_type,
       (q.resolution_condition ->> 'signal_id')::bigint AS signal_id,
       q.resolution_condition ->> 'op' AS op,
       (q.resolution_condition ->> 'value')::double precision AS threshold,
       COALESCE(q.resolution_condition ->> 'at', 'end_of_window') AS at,
       COALESCE(q.resolution_condition -> 'where', '{}'::jsonb) AS where_filter,
       COALESCE((q.resolution_condition #>> '{window,from}')::timestamptz, q.inserted_at) AS window_from,
       COALESCE((q.resolution_condition #>> '{window,to}')::timestamptz, q.deadline) AS window_to
FROM questions q
WHERE q.resolution_condition ->> 'type' IN ('series', 'events');

COMMENT ON VIEW rules.loop_question_window IS
  'A question with a series or events condition is resolved over its stated window, which defaults to creation time through deadline.';
