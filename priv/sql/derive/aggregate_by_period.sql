-- Derived operation "aggregate_by_period": count, sum or mean of one signal's
-- as-of observations for each complete period, optionally for each value of one
-- attribute (`group_by`). Count gives 0 for a complete period with no matching
-- observation. `observed_at` of a derived row is the latest observed_at among the
-- signal's observations that were known as of `as_of`.
CREATE FUNCTION derive.aggregate_by_period(
  p_signal_id bigint, p_period text, p_agg text, p_where jsonb, p_group_by text, p_as_of timestamptz)
RETURNS TABLE (source_record_id text, effective_at timestamptz, observed_at timestamptz,
               value double precision, attributes jsonb)
LANGUAGE sql STABLE AS $$
  WITH obs AS (
    SELECT o.* FROM observations_as_of(p_as_of) o WHERE o.signal_id = p_signal_id
  ),
  matched AS (
    SELECT o.*, fl.period_start(o.effective_at, p_period) AS p_start,
           CASE WHEN p_group_by IS NULL THEN NULL ELSE o.attributes ->> p_group_by END AS grp
    FROM obs o
    WHERE fl.attrs_match(o.attributes, p_where)
  ),
  bounds AS (
    SELECT fl.period_start(min(effective_at), p_period) AS first_start,
           max(observed_at) AS last_seen
    FROM obs
  ),
  periods AS (
    SELECT gs AS p_start
    FROM bounds, generate_series(bounds.first_start, p_as_of, fl.period_interval(p_period)) gs
    WHERE gs + fl.period_interval(p_period) <= p_as_of
  ),
  groups AS (
    SELECT DISTINCT grp FROM matched
    UNION SELECT NULL WHERE p_group_by IS NULL
  )
  SELECT
    fl.period_label(p.p_start, p_period) || COALESCE(':' || g.grp, ''),
    p.p_start,
    (SELECT last_seen FROM bounds),
    CASE p_agg
      WHEN 'count' THEN count(m.id)::double precision
      WHEN 'sum' THEN sum(m.value)
      WHEN 'mean' THEN avg(m.value)
    END,
    CASE WHEN p_group_by IS NULL
      THEN jsonb_build_object('period', fl.period_label(p.p_start, p_period))
      ELSE jsonb_build_object('period', fl.period_label(p.p_start, p_period), p_group_by, g.grp)
    END
  FROM periods p
  CROSS JOIN groups g
  LEFT JOIN matched m ON m.p_start = p.p_start AND m.grp IS NOT DISTINCT FROM g.grp
  WHERE g.grp IS NOT NULL OR p_group_by IS NULL
  GROUP BY p.p_start, g.grp
  HAVING p_agg = 'count' OR count(m.id) > 0
$$;
