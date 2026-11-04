-- A non-derived signal whose latest observed_at (as of batch_context.as_of) is older
-- than N cadence periods (config stale_source_multiple.cadence_multiple, default 2).
-- Cadence: daily, weekly, monthly, quarterly, yearly, or an ISO 8601 duration.
-- A signal with no observations counts from its creation time.
CREATE VIEW rules.gap_stale_source AS
WITH ctx AS (SELECT as_of FROM batch_context),
cfg AS (
  SELECT COALESCE((SELECT (value ->> 'cadence_multiple')::int FROM config WHERE key = 'stale_source_multiple'), 2) AS k
),
last_seen AS (
  SELECT o.signal_id, max(o.observed_at) AS t FROM ctx, observations_as_of(ctx.as_of) o GROUP BY o.signal_id
),
sig AS (
  SELECT s.id, s.name, s.cadence, COALESCE(l.t, s.inserted_at) AS since,
    fl.cadence_interval(s.cadence) AS period
  FROM signals s LEFT JOIN last_seen l ON l.signal_id = s.id
  WHERE s.kind <> 'derived'
)
SELECT sig.id::text AS subject_id,
       jsonb_build_object('signal', sig.name, 'cadence', sig.cadence, 'last_observed_at', sig.since) AS detail
FROM sig, ctx, cfg
WHERE sig.period IS NOT NULL AND sig.since < ctx.as_of - cfg.k * sig.period;

COMMENT ON VIEW rules.gap_stale_source IS
  'A source signal is a gap when nothing new has been observed for longer than the configured multiple of its cadence.';
