# 0003. Pin `fine` 0.1.x for the EXLA native build

- Status: accepted
- Date: 2026-11-03

## Context

EXLA (the Nx backend that compiles numerical code with Google's XLA compiler) builds a native library from C++ source. It uses the `fine` library (C++ helpers for Erlang native functions). EXLA 1.0.0 declares `{:fine, "~> 0.1"}`, which accepts any 0.x release. `fine` 0.2.0 was published on 2026-11-03 and changed its decoder interface. With it, the EXLA build fails with `no member named 'try_decode' in 'fine::Decoder<xla::Shape>'`.

## Decision

We add `{:fine, "~> 0.1.6", override: true, runtime: false}` to `mix.exs`.

## Consequences

EXLA builds. Remove the override when an EXLA release supports `fine` 0.2.
