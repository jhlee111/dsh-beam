# 0001. Elixir/OTP as the substrate

- **Status**: accepted
- **Date**: 2026-08-22
- **Deciders**: project author

## Context

The reference harness (DeepSeek Harness) is written in TypeScript on a Cordis
core; its theoretical basis is the "spatiotemporal composability" paper. We are
reproducing the *idea* on a fresh ecosystem, not porting the code. The paper
needs (1) revertible effects — pairing every state change with an inverse and
running inverses in LIFO order; (2) reactive coeffects — notifying components
when a dependency changes; (3) strong isolation between components so recovery
exactness ("remove only this fiber's contributions") is provable.

## Decision

Implement the harness in **Elixir on the BEAM (OTP)**, mapping the paper's
concepts onto OTP primitives:

- revertible effect → a closure returning `{new_state, inverse}`;
- LIFO accumulator → a list of inverse closures;
- effect independence → **process isolation** (separate processes share no
  state, so commutativity is given rather than assumed);
- lifecycle → `:gen_statem` + `DynamicSupervisor`;
- cross-node composition → `:erlang.dist`.

## Alternatives considered

- **Port the TS harness directly** — rejected: the goal is the design, not a
  code transplant; the TS runtime's module registry and Node-specific reload
  semantics would dominate the work.
- **Another BEAM language (Gleam, Erlang)** — rejected: Elixir's macro system
  (needed for the plugin DSL) and tooling (Mix, ExUnit, Phoenix) are the best
  fit for a declarative DSL + web console.

## Consequences

- Commutativity and fault isolation come "for free" from the runtime, which is
  precisely the PoC's research question — where the two reinforce vs collide.
- A fiber is coarser than the paper's *in-process* effect accumulator; the
  crash path can tear down the accumulator before inverses run (see ADR-0004).
- The DSL had to be built with `defmacro`/Spark rather than TypeScript's
  declaration merging.
