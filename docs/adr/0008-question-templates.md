# 0008. Question template patterns and periods

- Status: accepted
- Date: 2026-11-03

## Context

The prompt asks for question templates with a cadence and a window length, which the batch makes into one question for each period. It does not say how a pattern names the period, how the batch avoids duplicate questions, or which agent is the author.

## Decision

- A pattern uses `{{period}}`, `{{period_start}}`, `{{period_end}}` and `{{param.<name>}}` placeholders. The `rules.loop_template_due` view fills them, so the rendering is part of the rule layer.
- A period label is `YYYY-Www` (weekly, ISO week), `YYYY-MM` (monthly) or `YYYY-Qn` (quarterly).
- `window_length` is an ISO 8601 date duration such as `P3M`. PostgreSQL reads it directly as an `interval`.
- Each question made from a template stores `template_id` and `template_period`. A unique index on the pair makes instantiation idempotent.
- `question_templates.created_by_id` is the author. Template questions start in `review`, and a different agent must review each one before it goes live (ADR 0007).
- `starts_on` is the first period start. `active = false` stops new questions.

## Consequences

Two extra columns exist on `questions` (`template_period`) and `question_templates` (`key`, `params`, `starts_on`, `active`, `created_by_id`, `pack`) beyond the prompt's list.
