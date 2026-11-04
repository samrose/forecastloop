CREATE VIEW rules.loop_regime_shift_recent AS
SELECT rs.id AS regime_shift_id, rs.signal_id, rs.effective_at, rs.statistic, rs.p_value
FROM regime_shifts rs
CROSS JOIN batch_context ctx
CROSS JOIN (
  SELECT COALESCE((SELECT (value ->> 'days')::int FROM config WHERE key = 'regime_shift_recent_window'), 30) AS days
) cfg
WHERE rs.effective_at <= ctx.as_of
  AND rs.effective_at > ctx.as_of - make_interval(days => cfg.days);

COMMENT ON VIEW rules.loop_regime_shift_recent IS
  'A regime shift is recent when its effective_at falls within the configured trailing window before as_of.';
