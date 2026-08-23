# 0010. Phoenix LiveView (not React, Hologram, or live_react) for the UI

- **Status**: accepted
- **Date**: 2026-08-23
- **Deciders**: project author

## Context

The reference harness ships a large React client (Vite, `@deepseek-ai/dsh-client-*`
packages) with a slot registry abstraction (`ui-slots`). We need a UI that is
(1) consistent with "everything is a plugin" — a UI panel should be a plugin;
(2) compatible with the creator, which defines plugins *at runtime*; (3) light
enough to stay a PoC, not a second build pipeline.

## Decision

Build the UI in **Phoenix LiveView function components**, and reimplement the
slot-registry *concept* (not the React code) as the `ui_slot` DSL +
`DshBeam.Ui.render_slot/3`. Style comes from the reference design tokens
(vendored `dsw-design-platform.css`), not bespoke hex values.

## Alternatives considered

- **Reuse the reference React panels** via `live_react` — rejected: the panels
  are coupled to the cordis TypeScript runtime (`useSession`, `useProjection`,
  `ctx.*`), so "reuse" would still be a rewrite; and it drags in a
  Vite/Node/npm build pipeline, contradicting our "server-render + minimal JS"
  stance.
- **Hologram** (Elixir→JS compiler with dynamic component dispatch) — rejected:
  a second framework on top of Phoenix; and its compiler requires component
  modules to be *visible at build time as literals*, which the creator (runtime
  `defmodule` via `Code.compile_string`) fundamentally cannot satisfy.
- **Full React port of ui-slots** — rejected for the same runtime-coupling and
  build-pipeline reasons; the slot *idea* ports cleanly, the React *code* does
  not.

## Consequences

- A UI panel is a plugin (`ui_slot`), satisfying the core principle.
- Creator-defined plugins render server-side with no client-bundle problem.
- We give up React's ecosystem (existing component libraries); anything we want
  must be drawn in HEEx.
- If we later need a client-heavy interactive panel, this decision is the one to
  revisit (perhaps a scoped `live_react` island, not a wholesale rewrite).
