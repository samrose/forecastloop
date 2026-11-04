-- For each question with a series or events condition: the statistic over its window
-- [window_from, window_to) from as-of observations (rules.k_observation_normalized),
-- whether the condition is satisfied, and whether the outcome is already determined.
--
-- series end_of_window / mean_in_window: determined when the window has ended and an
--   observation exists in the window's last cadence period (data complete).
-- series any_in_window: satisfied (and determined) as soon as one value meets the op;
--   otherwise determined false when the window is complete.
-- events count>=: determined true as soon as the count reaches the value.
-- events count<=: determined false as soon as the count exceeds the value.
-- Events filter: `where` matches normalized attributes; `where.class` matches
-- rules.k_event_class.
CREATE VIEW rules.loop_condition_status AS
WITH ctx AS (SELECT as_of FROM batch_context),
w AS (
  SELECT w.*, s.cadence, s.id IS NOT NULL AS signal_exists
  FROM rules.loop_question_window w LEFT JOIN signals s ON s.id = w.signal_id
),
series AS (
  SELECT w.question_id,
         (array_agg(n.value ORDER BY n.effective_at DESC))[1] AS end_value,
         (array_agg(n.effective_at ORDER BY n.effective_at DESC))[1] AS end_effective_at,
         avg(n.value) AS mean_value,
         count(*) AS points,
         min(n.effective_at) FILTER (WHERE fl.compare(n.value, w.op, w.threshold)) AS first_hit_at
  FROM w
  JOIN rules.k_observation_normalized n
    ON n.signal_id = w.signal_id AND n.value IS NOT NULL
   AND n.effective_at >= w.window_from AND n.effective_at < w.window_to
  WHERE w.condition_type = 'series'
  GROUP BY w.question_id
),
events AS (
  SELECT w.question_id, count(n.observation_id) AS n_events,
         jsonb_agg(n.source_record_id ORDER BY n.effective_at) FILTER (WHERE n.observation_id IS NOT NULL) AS records
  FROM w
  LEFT JOIN rules.k_observation_normalized n
    ON n.signal_id = w.signal_id
   AND n.effective_at >= w.window_from AND n.effective_at < w.window_to
   AND fl.attrs_match(n.attributes, w.where_filter)
   AND (w.where_filter -> 'class' IS NULL OR EXISTS (
        SELECT 1 FROM rules.k_event_class c
        WHERE c.observation_id = n.observation_id
          AND CASE jsonb_typeof(w.where_filter -> 'class')
                WHEN 'array' THEN (w.where_filter -> 'class') @> to_jsonb(c.class)
                ELSE w.where_filter ->> 'class' = c.class END))
  WHERE w.condition_type = 'events'
  GROUP BY w.question_id
),
base AS (
  SELECT w.*, ctx.as_of,
         ctx.as_of >= w.window_to AS ended,
         s.end_value, s.end_effective_at, s.mean_value, s.points, s.first_hit_at,
         e.n_events, e.records,
         CASE w.condition_type
           WHEN 'series' THEN ctx.as_of >= w.window_to
             AND s.end_effective_at >= w.window_to - COALESCE(fl.cadence_interval(w.cadence), interval '1 day')
           ELSE ctx.as_of >= w.window_to
         END AS complete
  FROM w CROSS JOIN ctx
  LEFT JOIN series s ON s.question_id = w.question_id
  LEFT JOIN events e ON e.question_id = w.question_id
),
judged AS (
  SELECT b.*,
    CASE
      WHEN condition_type = 'events' THEN n_events::double precision
      WHEN at = 'end_of_window' THEN end_value
      WHEN at = 'mean_in_window' THEN mean_value
    END AS statistic,
    CASE
      WHEN condition_type = 'series' AND at = 'any_in_window' THEN first_hit_at IS NOT NULL
      WHEN condition_type = 'series' THEN COALESCE(complete AND fl.compare(
        CASE at WHEN 'end_of_window' THEN end_value ELSE mean_value END, op, threshold), false)
      WHEN op = 'count>=' THEN COALESCE(n_events >= threshold, false)
      WHEN op = 'count<=' THEN COALESCE(complete AND n_events <= threshold, false)
    END AS satisfied,
    CASE
      WHEN condition_type = 'series' AND at = 'any_in_window' THEN first_hit_at IS NOT NULL OR COALESCE(complete, false)
      WHEN condition_type = 'series' THEN COALESCE(complete, false)
      WHEN op = 'count>=' THEN COALESCE(n_events >= threshold, false) OR complete
      WHEN op = 'count<=' THEN COALESCE(n_events > threshold, false) OR complete
    END AS determined
  FROM base b
)
SELECT question_id, condition_type, signal_id, op, threshold, at, window_from, window_to,
       ended, complete, statistic, satisfied, determined,
       CASE WHEN determined THEN satisfied END AS outcome,
       jsonb_strip_nulls(jsonb_build_object(
         'as_of', as_of, 'signal_id', signal_id, 'op', op, 'threshold', threshold, 'at', at,
         'window_from', window_from, 'window_to', window_to, 'statistic', statistic,
         'points', points, 'end_effective_at', end_effective_at, 'first_hit_at', first_hit_at,
         'events', n_events, 'records', records)) AS evidence
FROM judged;

COMMENT ON VIEW rules.loop_condition_status IS
  'A series or events condition is satisfied, and its outcome determined, by the as-of observations in the question window.';
