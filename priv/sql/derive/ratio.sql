-- Derived operation "ratio": numerator / denominator for each source_record_id
-- present in both signals with a non-zero denominator. `observed_at` is the later
-- of the two inputs' observed_at.
CREATE FUNCTION derive.ratio(p_numerator bigint, p_denominator bigint, p_as_of timestamptz)
RETURNS TABLE (source_record_id text, effective_at timestamptz, observed_at timestamptz,
               value double precision, attributes jsonb)
LANGUAGE sql STABLE AS $$
  SELECT n.source_record_id, n.effective_at, greatest(n.observed_at, d.observed_at),
         n.value / d.value, n.attributes
  FROM observations_as_of(p_as_of) n
  JOIN observations_as_of(p_as_of) d
    ON d.signal_id = p_denominator AND d.source_record_id = n.source_record_id
  WHERE n.signal_id = p_numerator AND n.value IS NOT NULL AND d.value IS NOT NULL AND d.value <> 0
  ORDER BY n.effective_at, n.source_record_id
$$;
