-- Events that no knowledge rule classifies, in signals that have class rules.
-- A class_rule applies to a signal when its attributes.signal names the signal, or
-- when it names no signal and the event has the rule's attribute. A link_rule applies
-- to the first signal of its subject. An event is explicitly negative (not a gap)
-- when an applicable class_rule lists the event's value in attributes.negates.
CREATE VIEW rules.gap_unclassified_event AS
SELECT n.signal_id || ':' || n.source_record_id AS subject_id,
       jsonb_build_object('signal', n.signal_name, 'source_record_id', n.source_record_id,
                          'observation_id', n.observation_id, 'effective_at', n.effective_at,
                          'attributes', n.attributes) AS detail
FROM rules.k_observation_normalized n
WHERE n.signal_kind = 'events'
  AND EXISTS (
    SELECT 1 FROM knowledge_facts f
    WHERE (f.predicate = 'class_rule'
           AND (f.attributes ->> 'signal' = n.signal_name
                OR (f.attributes ->> 'signal' IS NULL AND n.attributes ? f.subject)))
       OR (f.predicate = 'link_rule'
           AND trim(split_part(replace(f.subject, '→', '->'), '->', 1)) = n.signal_name)
  )
  AND NOT EXISTS (SELECT 1 FROM rules.k_event_class c WHERE c.observation_id = n.observation_id)
  AND NOT EXISTS (
    SELECT 1 FROM knowledge_facts f
    WHERE f.predicate = 'class_rule'
      AND (f.attributes ->> 'signal' IS NULL OR f.attributes ->> 'signal' = n.signal_name)
      AND (f.valid_from IS NULL OR f.valid_from <= n.effective_at)
      AND (f.valid_to IS NULL OR n.effective_at < f.valid_to)
      AND jsonb_typeof(f.attributes -> 'negates') = 'array'
      AND EXISTS (
        SELECT 1 FROM jsonb_array_elements(
          CASE jsonb_typeof(n.attributes -> f.subject)
            WHEN 'array' THEN n.attributes -> f.subject
            ELSE jsonb_build_array(n.attributes -> f.subject) END) v(value)
        WHERE (f.attributes -> 'negates') @> jsonb_build_array(v.value))
  );

COMMENT ON VIEW rules.gap_unclassified_event IS
  'An event in a signal that has class rules is a gap when no rule classifies it and no applicable rule explicitly negates it.';
