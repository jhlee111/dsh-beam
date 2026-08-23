# 0002. Cordis substrate / harness-plugin layer split

- **Status**: accepted
- **Date**: 2026-08-22
- **Deciders**: project author

## Context

"Everything is a plugin" only holds if the *premise* (the substrate that makes
plugins composable) is clearly separated from the *plugins* (the things that do
work). The reference mirrors this as `vendor/cordis` vs `packages/*`.

## Decision

Split the tree into `lib/dsh/cordis/*` (Context, Effect/Coeffect/Fiber, Loader/
Runtime, the `use DshBeam.Plugin` macro + Spark DSL, Settings/Credential, Tool
registry) and `lib/dsh/*` (Session, Llm, Shell, Sandbox, Creator, Console,
Agent, tools). The substrate is not a plugin; it is what makes plugins true.

## Alternatives considered

- **One flat `lib/dsh/*`** — rejected after milestone 7; it obscured which
  modules were the framework and which were examples.

## Consequences

- New contributors can see "here is the substrate, here is a plugin built on it."
- The substrate cannot depend on any plugin (enforced by the split).
- The seam (`DshBeam.Session`, `DshBeam.Llm`) stays in the harness layer, which
  is the paper's Definition-owned call surface.
