-- Every as-of observation, with each string attribute value (and each string in an
-- array value) normalized: first through the `value_alias` fact for "<key>:<value>"
-- that is valid at the observation's effective_at, then, for an attribute that the
-- signal declares in source_spec.entity_attributes, through `entity_alias`.
CREATE VIEW rules.k_observation_normalized AS
WITH obs AS (
  SELECT o.*, s.name AS signal_name, s.kind AS signal_kind, s.domain AS signal_domain,
         COALESCE(s.source_spec -> 'entity_attributes', '[]'::jsonb) AS entity_attributes
  FROM batch_context ctx
  CROSS JOIN LATERAL observations_as_of(ctx.as_of) o
  JOIN signals s ON s.id = o.signal_id
),
elems AS (
  SELECT o.id, o.effective_at, o.entity_attributes, a.key, jsonb_typeof(a.value) AS kind,
         e.elem, e.ord
  FROM obs o
  CROSS JOIN LATERAL jsonb_each(o.attributes) a
  CROSS JOIN LATERAL jsonb_array_elements(
    CASE WHEN jsonb_typeof(a.value) = 'array' THEN a.value ELSE jsonb_build_array(a.value) END
  ) WITH ORDINALITY e(elem, ord)
),
normalized AS (
  SELECT el.id, el.key, el.kind, el.ord,
         CASE WHEN jsonb_typeof(el.elem) = 'string'
           THEN to_jsonb(COALESCE(ent.object, val.v))
           ELSE el.elem
         END AS nvalue
  FROM elems el
  CROSS JOIN LATERAL (
    SELECT COALESCE(
      (SELECT f.object FROM knowledge_facts f
       WHERE f.predicate = 'value_alias'
         AND f.subject = el.key || ':' || (el.elem #>> '{}')
         AND (f.valid_from IS NULL OR f.valid_from <= el.effective_at)
         AND (f.valid_to IS NULL OR el.effective_at < f.valid_to)
       ORDER BY f.valid_from DESC NULLS LAST, f.id LIMIT 1),
      el.elem #>> '{}') AS v
  ) val
  LEFT JOIN LATERAL (
    SELECT f.object FROM knowledge_facts f
    WHERE f.predicate = 'entity_alias'
      AND el.entity_attributes ? el.key
      AND f.subject = val.v
      AND (f.valid_from IS NULL OR f.valid_from <= el.effective_at)
      AND (f.valid_to IS NULL OR el.effective_at < f.valid_to)
    ORDER BY f.valid_from DESC NULLS LAST, f.id LIMIT 1
  ) ent ON true
),
rebuilt AS (
  SELECT id, jsonb_object_agg(key, v) AS attributes
  FROM (
    SELECT id, key,
           CASE WHEN min(kind) = 'array' THEN jsonb_agg(nvalue ORDER BY ord)
                ELSE (array_agg(nvalue))[1] END AS v
    FROM normalized
    GROUP BY id, key
  ) per_key
  GROUP BY id
)
SELECT o.id AS observation_id, o.signal_id, o.signal_name, o.signal_kind, o.signal_domain,
       o.entity_attributes, o.source_record_id, o.effective_at, o.observed_at, o.value,
       o.attributes AS raw_attributes,
       COALESCE(r.attributes, '{}'::jsonb) AS attributes
FROM obs o
LEFT JOIN rebuilt r ON r.id = o.id;

COMMENT ON VIEW rules.k_observation_normalized IS
  'An as-of observation has each string attribute value replaced by its value_alias valid at effective_at, and each declared entity attribute value replaced by its entity_alias.';
