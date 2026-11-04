-- The latest refresh of a signal = its as-of observations with the signal's latest
-- observed_at. Compare their (attribute key, JSON type) pairs with those of the
-- signal's as-of observations observed in the prior N days (config
-- definition_change_window.days, default 30). A signal with no prior observations
-- is not compared.
CREATE VIEW rules.gap_definition_change AS
WITH ctx AS (SELECT as_of FROM batch_context),
cfg AS (
  SELECT COALESCE((SELECT (value ->> 'days')::int FROM config WHERE key = 'definition_change_window'), 30) AS days
),
obs AS (SELECT o.* FROM ctx, observations_as_of(ctx.as_of) o),
latest AS (SELECT signal_id, max(observed_at) AS t FROM obs GROUP BY signal_id),
new_shape AS (
  SELECT DISTINCT o.signal_id, a.key, jsonb_typeof(a.value) AS type
  FROM obs o JOIN latest l ON l.signal_id = o.signal_id AND o.observed_at = l.t
  CROSS JOIN LATERAL jsonb_each(o.attributes) a
),
old_shape AS (
  SELECT DISTINCT o.signal_id, a.key, jsonb_typeof(a.value) AS type
  FROM obs o JOIN latest l ON l.signal_id = o.signal_id, cfg
  CROSS JOIN LATERAL jsonb_each(o.attributes) a
  WHERE o.observed_at < l.t AND o.observed_at >= l.t - make_interval(days => cfg.days)
),
changed AS (
  SELECT n.signal_id, n.key, n.type FROM new_shape n
  WHERE EXISTS (SELECT 1 FROM old_shape o WHERE o.signal_id = n.signal_id)
    AND NOT EXISTS (SELECT 1 FROM old_shape o WHERE o.signal_id = n.signal_id AND o.key = n.key AND o.type = n.type)
)
SELECT c.signal_id::text AS subject_id,
       jsonb_build_object('signal', s.name, 'refresh_observed_at', l.t,
         'new_keys', jsonb_agg(jsonb_build_object('key', c.key, 'type', c.type) ORDER BY c.key)) AS detail
FROM changed c
JOIN signals s ON s.id = c.signal_id
JOIN latest l ON l.signal_id = c.signal_id
GROUP BY c.signal_id, s.name, l.t;

COMMENT ON VIEW rules.gap_definition_change IS
  'A signal is a gap when its latest refresh has an attribute key or value type not seen in the prior observation window.';
