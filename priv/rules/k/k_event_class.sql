-- Classes of observations, from two kinds of knowledge fact:
--   class_rule: subject = attribute, object = class, attributes.equals = value or list,
--               attributes.signal = optional signal name the rule is limited to.
--   link_rule:  subject = "<signal A>-><signal B>" (or "→"), object = class,
--               attributes.on = shared entity attribute, or [attribute in A, attribute in B],
--               attributes.within = ISO 8601 duration. An observation in A gains the class
--               when an observation in B names the same entity and occurred within that
--               duration before it.
-- Facts must be valid at the classified observation's effective_at. reason = fact id.
-- An explicit negative beats a link: a link_rule gives no class to an observation
-- when a valid class_rule for the same class lists one of its values in
-- attributes.negates.
CREATE VIEW rules.k_event_class AS
SELECT DISTINCT n.observation_id, n.signal_id, f.object AS class, f.id AS reason, 'class_rule' AS rule
FROM rules.k_observation_normalized n
JOIN knowledge_facts f
  ON f.predicate = 'class_rule'
 AND (f.attributes ->> 'signal' IS NULL OR f.attributes ->> 'signal' = n.signal_name)
 AND (f.valid_from IS NULL OR f.valid_from <= n.effective_at)
 AND (f.valid_to IS NULL OR n.effective_at < f.valid_to)
WHERE EXISTS (
  SELECT 1
  FROM jsonb_array_elements(
    CASE jsonb_typeof(n.attributes -> f.subject)
      WHEN 'array' THEN n.attributes -> f.subject
      ELSE jsonb_build_array(n.attributes -> f.subject)
    END) v(value)
  WHERE v.value IS NOT NULL AND v.value <> 'null'::jsonb
    AND CASE jsonb_typeof(f.attributes -> 'equals')
          WHEN 'array' THEN (f.attributes -> 'equals') @> jsonb_build_array(v.value)
          ELSE (f.attributes -> 'equals') = v.value
        END
)
UNION
SELECT DISTINCT a.observation_id, a.signal_id, f.object, f.id, 'link_rule'
FROM knowledge_facts f
CROSS JOIN LATERAL (
  SELECT trim(split_part(replace(f.subject, '→', '->'), '->', 1)) AS sig_a,
         trim(split_part(replace(f.subject, '→', '->'), '->', 2)) AS sig_b,
         CASE jsonb_typeof(f.attributes -> 'on')
           WHEN 'array' THEN f.attributes -> 'on' ->> 0 ELSE f.attributes ->> 'on' END AS on_a,
         CASE jsonb_typeof(f.attributes -> 'on')
           WHEN 'array' THEN f.attributes -> 'on' ->> 1 ELSE f.attributes ->> 'on' END AS on_b,
         (f.attributes ->> 'within')::interval AS within
) p
JOIN rules.k_event_entity a
  ON a.signal_name = p.sig_a AND a.attribute = p.on_a
 AND (f.valid_from IS NULL OR f.valid_from <= a.effective_at)
 AND (f.valid_to IS NULL OR a.effective_at < f.valid_to)
JOIN rules.k_event_entity b
  ON b.signal_name = p.sig_b AND b.attribute = p.on_b AND b.entity = a.entity
 AND b.effective_at <= a.effective_at
 AND b.effective_at >= a.effective_at - p.within
WHERE f.predicate = 'link_rule'
  AND NOT EXISTS (
    SELECT 1
    FROM knowledge_facts neg
    JOIN rules.k_observation_normalized an ON an.observation_id = a.observation_id
    WHERE neg.predicate = 'class_rule'
      AND neg.object = f.object
      AND jsonb_typeof(neg.attributes -> 'negates') = 'array'
      AND (neg.attributes ->> 'signal' IS NULL OR neg.attributes ->> 'signal' = an.signal_name)
      AND (neg.valid_from IS NULL OR neg.valid_from <= an.effective_at)
      AND (neg.valid_to IS NULL OR an.effective_at < neg.valid_to)
      AND EXISTS (
        SELECT 1 FROM jsonb_array_elements(
          CASE jsonb_typeof(an.attributes -> neg.subject)
            WHEN 'array' THEN an.attributes -> neg.subject
            ELSE jsonb_build_array(an.attributes -> neg.subject) END) v(value)
        WHERE (neg.attributes -> 'negates') @> jsonb_build_array(v.value))
  );

COMMENT ON VIEW rules.k_event_class IS
  'An observation is in a class when a valid class_rule matches one of its attribute values, or a valid link_rule links it to an earlier observation on the same entity within the window and no class_rule explicitly negates it.';
