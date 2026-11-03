# 0006. The four Forecast Integrity Protocol fields

- Status: accepted
- Date: 2026-11-03

## Context

The prompt says that a question needs "all four Forecast Integrity Protocol fields" but does not name them. Peter Rothman's article defines the Forecast Integrity Protocol (FIP). We could not read the article from this environment, so this mapping is our interpretation and is not verified against his text.

## Decision

The four FIP fields of a question are:

1. `event_definition`: what exactly counts as the event.
2. `resolution_condition`: how the outcome is decided (manual, series or events).
3. `deadline`: when the question closes.
4. `domain`: which forecasting domain scores it, so calibration is compared like with like.

`Question.fip_changeset/2` requires all four. MCP and the UI create questions with it.

## Consequences

If the article defines the four fields differently, change `Question.fip_fields/0`, the `fip_before_live` constraint (ADR 0007) and this ADR.
