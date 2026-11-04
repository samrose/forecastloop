-- For each agent's latest forecast on a live question, each cited signal (the
-- condition's signal and the forecast's cited_signal_ids): the signal's latest
-- as-of value now, against its latest value as known at the forecast's made_at.
-- Stale when a newer observation exists and the change is more than
-- fraction_of_trailing_range x (max - min) of the trailing values. Trailing values:
-- effective_at within trailing_days of as_of, or the latest min_points values,
-- whichever is more. Config: stale_forecast_threshold.
CREATE VIEW rules.loop_stale_forecast AS
WITH ctx AS (SELECT as_of FROM batch_context),
cfg AS (
  SELECT COALESCE((c.value ->> 'fraction_of_trailing_range')::double precision, 0.10) AS fraction,
         COALESCE((c.value ->> 'trailing_days')::int, 30) AS days,
         COALESCE((c.value ->> 'min_points')::int, 12) AS min_points
  FROM (SELECT NULL) d LEFT JOIN config c ON c.key = 'stale_forecast_threshold'
),
latest_f AS (
  SELECT DISTINCT ON (f.question_id, f.agent_id) f.*, q.resolution_condition
  FROM forecasts f
  JOIN questions q ON q.id = f.question_id AND q.status = 'live'
  CROSS JOIN ctx
  WHERE f.made_at <= ctx.as_of
  ORDER BY f.question_id, f.agent_id, f.made_at DESC, f.id DESC
),
cited AS (
  SELECT DISTINCT lf.question_id, lf.agent_id, lf.id AS forecast_id, lf.made_at, c.signal_id
  FROM latest_f lf
  CROSS JOIN LATERAL (
    SELECT (lf.resolution_condition ->> 'signal_id')::bigint
    UNION SELECT unnest(lf.cited_signal_ids)
  ) c(signal_id)
  WHERE c.signal_id IS NOT NULL
),
points AS (
  SELECT n.signal_id, n.value, n.effective_at, n.observed_at,
         row_number() OVER (PARTITION BY n.signal_id ORDER BY n.effective_at DESC) AS rn
  FROM rules.k_observation_normalized n
  WHERE n.value IS NOT NULL
),
now_v AS (SELECT signal_id, value, effective_at, observed_at FROM points WHERE rn = 1),
spread AS (
  SELECT p.signal_id, max(p.value) - min(p.value) AS range
  FROM points p, ctx, cfg
  WHERE p.effective_at >= ctx.as_of - make_interval(days => cfg.days) OR p.rn <= cfg.min_points
  GROUP BY p.signal_id
),
compared AS (
  SELECT c.*, nv.value AS now_value, nv.observed_at AS now_observed_at,
         (SELECT o.value FROM observations_as_of(c.made_at) o
          WHERE o.signal_id = c.signal_id AND o.value IS NOT NULL
          ORDER BY o.effective_at DESC LIMIT 1) AS then_value,
         sp.range * cfg.fraction AS threshold
  FROM cited c
  JOIN now_v nv ON nv.signal_id = c.signal_id
  JOIN spread sp ON sp.signal_id = c.signal_id
  CROSS JOIN cfg
)
SELECT question_id || ':' || agent_id AS subject_id,
       jsonb_build_object('question_id', question_id, 'agent_id', agent_id,
         'forecast_id', forecast_id, 'made_at', made_at,
         'signals', jsonb_agg(jsonb_build_object('signal_id', signal_id, 'then', then_value,
                     'now', now_value, 'threshold', threshold) ORDER BY signal_id)) AS detail
FROM compared
WHERE now_observed_at > made_at
  AND threshold > 0
  AND (then_value IS NULL OR abs(now_value - then_value) > threshold)
GROUP BY question_id, agent_id, forecast_id, made_at;

COMMENT ON VIEW rules.loop_stale_forecast IS
  'An agent''s latest forecast on a live question is stale when a cited signal has moved by more than the configured share of its trailing range since the forecast.';
