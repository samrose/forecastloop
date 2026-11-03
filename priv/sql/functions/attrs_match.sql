-- True when every key of `filter` (except "class") matches `attrs`. A filter value
-- that is a JSON array matches any of its elements; any other value must be equal.
-- The "class" key refers to rules.k_event_class and the caller tests it.
CREATE FUNCTION fl.attrs_match(attrs jsonb, filter jsonb)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT NOT EXISTS (
    SELECT 1 FROM jsonb_each(COALESCE(filter, '{}'::jsonb)) f
    WHERE f.key <> 'class'
      AND NOT COALESCE(
        CASE jsonb_typeof(f.value)
          WHEN 'array' THEN f.value @> jsonb_build_array(attrs -> f.key)
          ELSE attrs -> f.key = f.value
        END, false)
  )
$$;
