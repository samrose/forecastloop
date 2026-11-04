-- For each active template: the period after the one that contains as_of, rendered.
-- The question window is [period start, period start + window_length) and the deadline
-- is the window end. A pattern can name its signal with "signal": "<name>"; the view
-- turns it into "signal_id". `problem` is set when the question cannot be made.
CREATE VIEW rules.loop_template_due AS
WITH ctx AS (SELECT as_of FROM batch_context),
nxt AS (
  SELECT t.*, fl.period_start(ctx.as_of, t.cadence) + fl.period_interval(t.cadence) AS p_start
  FROM question_templates t CROSS JOIN ctx
  WHERE t.active
),
periods AS (
  SELECT n.*, fl.period_label(n.p_start, n.cadence) AS label,
         n.p_start + n.window_length::interval AS p_end
  FROM nxt n
  WHERE n.p_start >= n.starts_on
),
vars AS (
  SELECT p.*,
         jsonb_build_object(
           'period', p.label,
           'period_start', to_char(p.p_start AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
           'period_end', to_char(p.p_end AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'))
         || COALESCE((SELECT jsonb_object_agg('param.' || kv.key, kv.value) FROM jsonb_each(p.params) kv), '{}')
           AS v
  FROM periods p
),
rendered AS (
  SELECT v.*, fl.render_json(v.resolution_condition_pattern, v.v) AS rc0 FROM vars v
),
resolved AS (
  SELECT r.*,
         CASE WHEN r.rc0 ? 'signal' THEN (SELECT s.id FROM signals s WHERE s.name = r.rc0 ->> 'signal') END AS named_signal_id
  FROM rendered r
)
SELECT r.id AS template_id, r.key AS template_key, r.label AS period, r.p_start AS period_start,
       r.p_end AS period_end, r.domain, r.created_by_id,
       fl.render(r.title_pattern, r.v) AS title,
       fl.render(r.event_definition_pattern, r.v) AS event_definition,
       (CASE WHEN r.rc0 ? 'signal'
             THEN (r.rc0 - 'signal') || jsonb_build_object('signal_id', r.named_signal_id)
             ELSE r.rc0 END)
       || CASE WHEN r.rc0 ? 'window' THEN '{}'::jsonb
               ELSE jsonb_build_object('window', jsonb_build_object('from', r.v ->> 'period_start', 'to', r.v ->> 'period_end')) END
         AS resolution_condition,
       r.p_end AS deadline,
       CASE WHEN r.rc0 ? 'signal' AND r.named_signal_id IS NULL THEN 'unknown_signal:' || (r.rc0 ->> 'signal') END AS problem
FROM resolved r
WHERE NOT EXISTS (
  SELECT 1 FROM questions q WHERE q.template_id = r.id AND q.template_period = r.label
);

COMMENT ON VIEW rules.loop_template_due IS
  'An active template is due when the period after the current one has no question from it yet.';
