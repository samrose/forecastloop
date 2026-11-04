# 0014. Own E-Divisive implementation

- Status: accepted (replace when the provided module arrives)
- Date: 2026-11-03

## Context

The prompt says "use the provided `EDivisive` module (in `lib/e_divisive.ex`; copy it in unchanged and keep its tests passing)". The file was not in the empty start directory, and it was not supplied when asked.

## Decision

We wrote `lib/e_divisive.ex` with the contract `EDivisive.detect(series, opts) :: [%{index, statistic, p_value}]`. The module follows Matteson and James (2014):

- It uses the energy divergence statistic Q, with distance exponent `alpha`.
- It splits a series hierarchically.
- It runs a permutation test with a fixed seed.

It fixes the end of each candidate interval at the segment end. EXLA compiles the statistic once for each segment length.

The default `sig_level` is 0.01, not 0.05. Each split is a separate test. At 0.05, uniform noise segments gave false splits with p-values of 0.025 and 0.05 in the tests. With 199 permutations the smallest p-value is 0.005.

## Consequences

To use the provided module, replace `lib/e_divisive.ex` and its tests. `ForecastLoop.Batch.Changepoints` calls only `detect/2` and `defaults/0`. Check that the provided module has a `defaults/0` function, or change `Changepoints.options/0`. The module must be deterministic, because the batch must be idempotent.
