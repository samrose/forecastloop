# 0005. As-of access is keyed by source record

- Status: accepted
- Date: 2026-11-03

## Context

The prompt says `Observations.as_of/2` returns, "per (signal_id, effective_at)", the row with the latest `observed_at <= t`. For an events signal, two records can share an `effective_at`. Also, a revision can correct the `effective_at` of a record. If the key were `effective_at`, two events at the same moment would collapse into one, and a corrected timestamp would leave a stale copy.

## Decision

The as-of key is `(signal_id, source_record_id)`. This is the record identity that the unique index `(signal_id, source_record_id, observed_at)` already defines. For a series signal, a source gives one record for each period, so `source_record_id` identifies the period. The result is then the same as keying by `effective_at`.

The query is defined once, as the SQL function `observations_as_of(t)`. `ForecastLoop.Observations.as_of/2` calls it. The rule views call it with `batch_context.as_of`.

## Consequences

A source adapter must give a stable `source_record_id`. For a series, that is the period key, for example `2026-09`.
