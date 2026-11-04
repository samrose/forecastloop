# 0007. A database constraint guards the "live" invariant, and a rule drives promotion

- Status: accepted
- Date: 2026-11-03

## Context

A question must not go live without the FIP fields and a reviewer who is not its author. The prompt says that no rule logic may live in Elixir. The view `rules.loop_live_question` lists the questions that may go live. But a person or a bug can still write `status = 'live'` directly.

## Decision

- The rule: `rules.loop_live_question` decides which questions to promote. The batch promotes exactly those rows.
- The invariant: the CHECK constraint `questions.fip_before_live` rejects any `live` or `resolved` row that lacks a FIP field, lacks a reviewer, or has `reviewed_by_id = created_by_id`.

The constraint is a data-integrity guard, not a rule that the loop acts on. The view and the constraint state the same condition.

## Consequences

The condition exists in two places. A test checks that every row the view lists passes the constraint, and that the constraint rejects a self-reviewed question.
