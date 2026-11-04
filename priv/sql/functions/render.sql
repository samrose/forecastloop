-- Fills {{name}} placeholders in a text from a JSON object of variables.
CREATE FUNCTION fl.render(pattern text, vars jsonb)
RETURNS text LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  out text := pattern;
  kv record;
BEGIN
  FOR kv IN SELECT key, value FROM jsonb_each(vars) LOOP
    out := replace(out, '{{' || kv.key || '}}',
                   CASE jsonb_typeof(kv.value) WHEN 'string' THEN kv.value #>> '{}' ELSE kv.value::text END);
  END LOOP;
  RETURN out;
END;
$$;

-- Fills placeholders in a JSON value. A string that is exactly "{{name}}" becomes the
-- variable's JSON value (so a number stays a number); other placeholders are filled
-- as text.
CREATE FUNCTION fl.render_json(pattern jsonb, vars jsonb)
RETURNS jsonb LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  out text := pattern::text;
  kv record;
BEGIN
  FOR kv IN SELECT key, value FROM jsonb_each(vars) LOOP
    out := replace(out, '"{{' || kv.key || '}}"', kv.value::text);
  END LOOP;
  FOR kv IN SELECT key, value FROM jsonb_each(vars) LOOP
    out := replace(out, '{{' || kv.key || '}}',
                   CASE jsonb_typeof(kv.value) WHEN 'string' THEN kv.value #>> '{}' ELSE kv.value::text END);
  END LOOP;
  RETURN out::jsonb;
END;
$$;
