# 0011. Disable the Phoenix code reloader in dev

- **Status**: accepted
- **Date**: 2026-08-23
- **Deciders**: project author

## Context

The console runs via `mix run scripts/console.exs` (not `mix phx.server`), and
we initially enabled Phoenix 1.8's `Phoenix.CodeReloader` (config + Mix
`listeners` + endpoint plug) so edits reflected without restart.

## Decision

**Disable the code reloader** (`code_reloader: false`, remove the plug and the
Mix `listeners` entry) and restart explicitly after edits.

## Alternatives considered

- **Keep the reloader** — rejected after two failures: it cannot survive a
  config-file change (raises "restart your server"), and a mid-edit compile
  error leaves the VM serving a poisoned `CompileError` page that kills the
  LiveView socket. A poisoned demo is worse than a manual restart.

## Consequences

- The demo server is stable across edits; nothing recompiles mid-request.
- Edits require a restart (acceptable for a PoC console).
- This is a dev-experience decision, not a production one — a real deploy
  compiles once anyway.
