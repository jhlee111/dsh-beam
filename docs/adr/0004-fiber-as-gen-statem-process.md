# 0004. Promote the fiber to a `:gen_statem` process

- **Status**: accepted
- **Date**: 2026-08-22
- **Deciders**: project author (in response to review M5)

## Context

The paper's central tension is the *fiber-unit fine-grained accumulator* vs
OTP's *process-unit* isolation. The first implementation kept fibers as 2-state
map records inside a single `Context` GenServer — which review finding M5
flagged as *not actually demonstrating* the tension: coordination was piled
into one process, and fault isolation ("siblings keep running") was bypassed.

## Decision

Promote each fiber to a **`:gen_statem` process** with four states
(`inactive`/`active`/`reloading`/`unloading`), supervised by a
`DynamicSupervisor`. The `Context` keeps the unified binding/coefficient map
and the pending-unload machine, but a fiber's lifecycle is its own process.

## Alternatives considered

- **Keep the 2-state map record** — rejected: it did not demonstrate the
  paper's claim and collapsed fault isolation.
- **Full supervision-tree reflection of the calculus** — rejected as
  over-engineering for a PoC; `:gen_statem` + `DynamicSupervisor` captures the
  lifecycle without a bespoke supervisor strategy.

## Consequences

- Crash-path recovery and sibling survival are real, testable properties.
- The committed view (provider resources outlive dependents' teardown) required
  an ordered-shutdown pass on top (milestone 2-②) — evidence of the collision
  documented in PLAN §22.
- Synchronous `:gen_statem.call` re-entrancy became a recurring trap (REVIEW
  H1), worked around by message-driven withdrawal.
