# 0013. Scoring and calibration definitions

- Status: accepted
- Date: 2026-11-03

## Context

The prompt asks for Brier and log scores, decile buckets, a skill score against a base rate, and the Murphy decomposition. It does not define the sign of the log score, which forecasts count when an agent revises, or which base rate the skill score uses.

## Decision

- `log_score` is the natural log of the probability that the forecast gave to the actual outcome. The probability is clipped to [0.01, 0.99]. The score is 0 or less, and higher is better.
- `cal_score` scores every forecast that was made at or before the resolution. A forecast made after the resolution is not scored.
- `is_final` marks the last forecast of each agent on each question. `cal_bucket`, `cal_summary` and `cal_drift` use only final forecasts, so each question gives one vote for each agent.
- The skill score is the Brier skill score `1 - mean_brier / (obar (1 - obar))`. Here `obar` is the base rate of the same questions. A skill of 0 equals "always forecast the base rate".
- The Murphy decomposition uses the decile buckets. It is exact only when each bucket holds one probability value. The test fixture shows the size of the difference.
- `cal_drift` compares the mean Brier of final forecasts on questions resolved in the recent window with the window before it. The `drift_windows` config row sets the window lengths, the margin and the minimum count.
- `scores` is a full sync of `cal_score`. The sync deletes the rows that left the view, inserts new rows, and updates a row only when its values change.

## Consequences

A revision does not dilute an agent's calibration, because only the final forecast counts. All of the agent's forecasts still have a row in `scores`.
