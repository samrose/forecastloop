-- Derived operation "aggregate_by_period": count, sum or mean of one signal's
-- as-of observations for each complete period, optionally for each value of one
-- attribute (`group_by`). Count gives 0 for a complete period with no matching
-- observation. `observed_at` of a derived row is the latest observed_at among the
-- signal's observations that were known as of `as_of`. A "class" key in `where`
-- (a class name or a list) keeps only observations that rules.k_event_class puts in
-- that class; k_event_class reads batch_context.as_of, so call this function with
-- p_as_of = batch_context.as_of when you filter by class.
-- Completeness: a period is complete when as_of is at or after its end. For "sum"
-- and "mean", the input must also have a value in the period's last input-cadence
-- step (the input signal's cadence, default 1 day), so a quarter is not summed
-- before its last month is published.
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
      AND (p_where -> 'class' IS NULL OR EXISTS (
        SELECT 1 FROM rules.k_event_class c
        WHERE c.observation_id = o.id
          AND CASE jsonb_typeof(p_where -> 'class')
                WHEN 'array' THEN (p_where -> 'class') @> to_jsonb(c.class)
                ELSE p_where ->> 'class' = c.class END))
  ),
  bounds AS (
    SELECT fl.period_start(min(effective_at), p_period) AS first_start,
           max(observed_at) AS last_seen,
           max(effective_at) AS last_effective_at,
           COALESCE((SELECT fl.cadence_interval(s.cadence) FROM signals s WHERE s.id = p_signal_id),
                    interval '1 day') AS step
    FROM obs
  ),
  periods AS (
    SELECT gs AS p_start
    FROM bounds, generate_series(bounds.first_start, p_as_of, fl.period_interval(p_period)) gs
    WHERE gs + fl.period_interval(p_period) <= p_as_of
      AND (p_agg = 'count'
           OR bounds.last_effective_at >= gs + fl.period_interval(p_period) - bounds.step)
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
  ORDER BY p.p_start, g.grp
$$;
