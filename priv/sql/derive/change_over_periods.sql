-- Derived operation "change_over_periods": for a series with one observation per
-- period, the difference (or percent change) from the value `p_lag` periods
-- earlier. `observed_at` is the later of the two inputs' observed_at.
CREATE FUNCTION derive.change_over_periods(
  p_signal_id bigint, p_lag integer, p_mode text, p_as_of timestamptz)
RETURNS TABLE (source_record_id text, effective_at timestamptz, observed_at timestamptz,
               value double precision, attributes jsonb)
LANGUAGE sql STABLE AS $$
  SELECT s.source_record_id, s.effective_at, greatest(s.observed_at, s.prev_observed_at),
         CASE p_mode
           WHEN 'percent' THEN 100.0 * (s.value - s.prev_value) / NULLIF(s.prev_value, 0)
           ELSE s.value - s.prev_value
         END,
         jsonb_build_object('lag', p_lag, 'mode', p_mode)
  FROM (
    SELECT o.*,
           lag(o.value, p_lag) OVER w AS prev_value,
           lag(o.observed_at, p_lag) OVER w AS prev_observed_at
    FROM observations_as_of(p_as_of) o
    WHERE o.signal_id = p_signal_id AND o.value IS NOT NULL
    WINDOW w AS (ORDER BY o.effective_at, o.source_record_id)
  ) s
  WHERE s.prev_value IS NOT NULL
    AND (p_mode <> 'percent' OR s.prev_value <> 0)
$$;
