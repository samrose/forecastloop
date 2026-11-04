-- Per domain, mean Brier of final forecasts on questions resolved in the recent
-- window (recent_days before as_of) against the baseline window (the baseline_days
-- before the recent window). Drift when recent - baseline > margin and each window
-- has at least min_n scores. Config: drift_windows.
CREATE VIEW rules.cal_drift AS
WITH ctx AS (SELECT as_of FROM batch_context),
cfg AS (
  SELECT COALESCE((c.value ->> 'recent_days')::int, 90) AS recent_days,
         COALESCE((c.value ->> 'baseline_days')::int, 365) AS baseline_days,
         COALESCE((c.value ->> 'margin')::double precision, 0.05) AS margin,
         COALESCE((c.value ->> 'min_n')::int, 3) AS min_n
  FROM (SELECT NULL) d LEFT JOIN config c ON c.key = 'drift_windows'
),
windows AS (
  SELECT s.domain,
         avg(s.brier) FILTER (WHERE s.resolved_at > ctx.as_of - make_interval(days => cfg.recent_days)) AS recent_brier,
         count(*) FILTER (WHERE s.resolved_at > ctx.as_of - make_interval(days => cfg.recent_days)) AS recent_n,
         avg(s.brier) FILTER (WHERE s.resolved_at <= ctx.as_of - make_interval(days => cfg.recent_days)
                                AND s.resolved_at > ctx.as_of - make_interval(days => cfg.recent_days + cfg.baseline_days)) AS baseline_brier,
         count(*) FILTER (WHERE s.resolved_at <= ctx.as_of - make_interval(days => cfg.recent_days)
                            AND s.resolved_at > ctx.as_of - make_interval(days => cfg.recent_days + cfg.baseline_days)) AS baseline_n,
         cfg.margin, cfg.min_n
  FROM rules.cal_score s CROSS JOIN ctx CROSS JOIN cfg
  WHERE s.is_final
  GROUP BY s.domain, cfg.margin, cfg.min_n
)
SELECT domain, recent_brier, recent_n, baseline_brier, baseline_n, recent_brier - baseline_brier AS deterioration
FROM windows
WHERE recent_n >= min_n AND baseline_n >= min_n AND recent_brier - baseline_brier > margin;

COMMENT ON VIEW rules.cal_drift IS
  'A domain drifts when the mean Brier of its recently resolved forecasts exceeds the baseline window''s mean Brier by the configured margin.';
