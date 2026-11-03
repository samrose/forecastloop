# 0001. Record decisions as ADRs

- Status: accepted
- Date: 2026-11-03

## Context

The build prompt asks for a `DECISIONS.md` file that records each choice the prompt leaves open. The project owner asked for these choices to be recorded as ADRs (Architecture Decision Records). An ADR is one short file for one decision, with its context, the choice, and its consequences.

## Decision

We write each decision as `docs/adr/NNNN-kebab-title.md`, from the template `docs/adr/0000-template.md`. We keep `DECISIONS.md` as an index with one line for each ADR. We do not edit an accepted ADR to change its decision. We write a new ADR that supersedes it.

## Consequences

A reader can find the reason for a choice from the index in one step. The history of a changed decision stays visible.
