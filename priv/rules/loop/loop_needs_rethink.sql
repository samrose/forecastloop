-- Scenario -> assumption -> question chains. An assumption is falsified when its
-- question resolved false.
CREATE VIEW rules.loop_needs_rethink AS
SELECT s.id::text AS subject_id,
       jsonb_build_object('scenario_id', s.id, 'title', s.title,
         'falsified', jsonb_agg(jsonb_build_object('assumption_id', a.id, 'statement', a.statement,
                        'question_id', q.id, 'resolved_at', r.resolved_at) ORDER BY a.id)) AS detail
FROM scenarios s
JOIN assumptions a ON a.scenario_id = s.id
JOIN questions q ON q.id = a.question_id
JOIN resolutions r ON r.question_id = q.id
WHERE s.status = 'active' AND r.outcome = false
GROUP BY s.id, s.title;

COMMENT ON VIEW rules.loop_needs_rethink IS
  'An active scenario needs rethinking when one of its assumptions is tested by a question that resolved false.';
