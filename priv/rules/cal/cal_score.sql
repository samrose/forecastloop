-- One row for each (forecast, resolution) known at batch_context.as_of: the forecast
-- was made at or before the resolution, and both are at or before as_of.
-- brier = (p - o)^2. log_score = ln(probability given to the actual outcome), with p
-- clipped to [0.01, 0.99]; it is <= 0 and higher is better. is_final marks each
-- agent's last forecast on the question; calibration views use only final forecasts.
CREATE VIEW rules.cal_score AS
WITH ctx AS (SELECT as_of FROM batch_context)
SELECT f.id AS forecast_id, f.question_id, f.agent_id, f.model_version_id, q.domain,
       f.probability, r.outcome, r.resolved_at, f.made_at,
       power(f.probability - CASE WHEN r.outcome THEN 1 ELSE 0 END, 2) AS brier,
       ln(CASE WHEN r.outcome THEN least(greatest(f.probability, 0.01), 0.99)
               ELSE 1 - least(greatest(f.probability, 0.01), 0.99) END) AS log_score,
       f.id = first_value(f.id) OVER (PARTITION BY f.question_id, f.agent_id
                                      ORDER BY f.made_at DESC, f.id DESC) AS is_final
FROM forecasts f
JOIN questions q ON q.id = f.question_id
JOIN resolutions r ON r.question_id = f.question_id
CROSS JOIN ctx
WHERE f.made_at <= r.resolved_at AND r.resolved_at <= ctx.as_of;

COMMENT ON VIEW rules.cal_score IS
  'A forecast made before its question''s resolution scores Brier (p - o)^2 and log ln(clipped probability of the actual outcome).';
