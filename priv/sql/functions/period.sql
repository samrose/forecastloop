-- Calendar periods for cadences 'weekly' (ISO week), 'monthly' and 'quarterly', in UTC.

CREATE FUNCTION fl.period_start(ts timestamptz, cadence text)
RETURNS timestamptz LANGUAGE sql IMMUTABLE STRICT AS $$
  SELECT date_trunc(
    CASE cadence WHEN 'weekly' THEN 'week' WHEN 'monthly' THEN 'month' WHEN 'quarterly' THEN 'quarter' END,
    ts, 'UTC')
$$;

CREATE FUNCTION fl.period_interval(cadence text)
RETURNS interval LANGUAGE sql IMMUTABLE STRICT AS $$
  SELECT CASE cadence
    WHEN 'weekly' THEN interval '1 week'
    WHEN 'monthly' THEN interval '1 month'
    WHEN 'quarterly' THEN interval '3 months'
  END
$$;

-- Label of the period that starts at `start`: 2026-W45, 2026-11 or 2026-Q4.
CREATE FUNCTION fl.period_label(start timestamptz, cadence text)
RETURNS text LANGUAGE sql IMMUTABLE STRICT AS $$
  SELECT to_char(start AT TIME ZONE 'UTC',
    CASE cadence WHEN 'weekly' THEN 'IYYY-"W"IW' WHEN 'monthly' THEN 'YYYY-MM' WHEN 'quarterly' THEN 'YYYY-"Q"Q' END)
$$;

-- Length of a signal cadence: daily, weekly, monthly, quarterly, yearly/annual, or an
-- ISO 8601 duration (for example P1M). NULL when unknown.
CREATE FUNCTION fl.cadence_interval(cadence text)
RETURNS interval LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE cadence
    WHEN 'daily' THEN interval '1 day' WHEN 'weekly' THEN interval '1 week'
    WHEN 'monthly' THEN interval '1 month' WHEN 'quarterly' THEN interval '3 months'
    WHEN 'yearly' THEN interval '1 year' WHEN 'annual' THEN interval '1 year'
    ELSE CASE WHEN cadence ~ '^P[0-9YMWDTHS]+$' THEN cadence::interval END
  END
$$;

-- a <op> b for op in >=, <=, >, <, ==. NULL when a or b is NULL.
CREATE FUNCTION fl.compare(a double precision, op text, b double precision)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE op WHEN '>=' THEN a >= b WHEN '<=' THEN a <= b WHEN '>' THEN a > b
                 WHEN '<' THEN a < b WHEN '==' THEN a = b END
$$;
