# 0010. Refresh: when to append a vintage, and what a shape change is

- Status: accepted
- Date: 2026-11-03

## Context

The batch must be idempotent: two runs on the same data change only `runs`. Most sources (a CSV file, a CSV URL, a query) return the full data set on every fetch and say nothing about when a value was published. Some sources (for example FRED's vintage data) give a publication date per value. The prompt also asks for a `definition_change` work item when a fetch has a "changed row shape", but does not define the shape.

## Decision

**Vintages.** For each record, the refresh step compares the fetched rows with the latest stored vintage, read through `Observations.as_of/2`. It walks the record's fetched rows in `observed_at` order and appends a row only when both conditions are true:

1. Its `observed_at` is later than the latest vintage that we hold.
2. Its content (`effective_at`, `value`, `attributes`) differs from the vintage before it.

When a source has no publication column, `observed_at` is the fetch time. When a spec maps a column to `observed_at`, the refresh step uses that column.

**Shape.** A spec's `fields` declare the columns that it needs. If a declared column is missing from the fetched data, the source returns `{:error, {:shape_changed, ...}}`. The refresh step then opens a `definition_change` work item and ingests nothing for that signal. New, undeclared columns are not a shape change. The `gap_definition_change` rule (phase 3) finds changes in attribute keys and value types after ingest.

**Atomicity.** All rows of a signal are mapped and validated before any insert, then inserted in one transaction. A successful refresh closes that signal's open `refresh_failed` and `definition_change` work items.

## Consequences

- An unchanged refresh appends nothing, and the signal row is not updated.
- A vintage older than the newest stored vintage of its record is not back-filled. To load older history, load it before newer data, or load it into a new signal.
- A derived row's `observed_at` is the latest `observed_at` of its inputs, so recomputing derived data that has not changed appends nothing.
