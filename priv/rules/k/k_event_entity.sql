-- One row for each entity that an observation names: each string (or string in an
-- array) of each attribute listed in the signal's source_spec.entity_attributes,
-- after normalization.
CREATE VIEW rules.k_event_entity AS
SELECT n.observation_id, n.signal_id, n.signal_name, n.effective_at, ea.attribute,
       e.entity
FROM rules.k_observation_normalized n
CROSS JOIN LATERAL jsonb_array_elements_text(n.entity_attributes) ea(attribute)
CROSS JOIN LATERAL jsonb_array_elements_text(
  CASE jsonb_typeof(n.attributes -> ea.attribute)
    WHEN 'array' THEN n.attributes -> ea.attribute
    WHEN 'string' THEN jsonb_build_array(n.attributes -> ea.attribute)
    ELSE '[]'::jsonb
  END
) e(entity);

COMMENT ON VIEW rules.k_event_entity IS
  'An observation names an entity when a declared entity attribute holds that (normalized) entity name.';
