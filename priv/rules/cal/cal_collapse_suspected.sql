-- Predictability collapse (Rothman: H(Future) - H(Future | Present) falls towards 0)
-- is suspected in a domain when forecasts there have drifted worse AND a signal that
-- the domain's questions cite (condition signal or forecast cited_signal_ids) had a
-- recent regime shift.
CREATE VIEW rules.cal_collapse_suspected AS
WITH cited AS (
  SELECT q.domain, (q.resolution_condition ->> 'signal_id')::bigint AS signal_id
  FROM questions q WHERE q.resolution_condition ? 'signal_id'
  UNION
  SELECT q.domain, unnest(f.cited_signal_ids)
  FROM forecasts f JOIN questions q ON q.id = f.question_id
)
SELECT d.domain, d.recent_brier, d.baseline_brier, d.deterioration,
       jsonb_agg(DISTINCT jsonb_build_object('regime_shift_id', rs.regime_shift_id,
         'signal_id', rs.signal_id, 'effective_at', rs.effective_at)) AS shifts
FROM rules.cal_drift d
JOIN cited c ON c.domain = d.domain
JOIN rules.loop_regime_shift_recent rs ON rs.signal_id = c.signal_id
GROUP BY d.domain, d.recent_brier, d.baseline_brier, d.deterioration;

COMMENT ON VIEW rules.cal_collapse_suspected IS
  'Predictability collapse is suspected in a domain when its forecasts have drifted worse and a signal its questions cite had a recent regime shift.';
