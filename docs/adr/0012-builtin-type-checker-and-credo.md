# 0012. Built-in type checker + scoped Credo (no dialyzer)

- **Status**: accepted
- **Date**: 2026-08-23
- **Deciders**: project author

## Context

We wanted static analysis beyond the compiler but had to pick a tool. Elixir
1.18+ ships a built-in type checker (undefined functions, unused defs) that Mix
enables by default; Dialyzer and Credo are the traditional additions.

## Decision

- Rely on the **built-in type checker** via `mix compile --warnings-as-errors`
  (already in CI) — no Dialyzer.
- Add **Credo scoped to bug-catching checks only** (`.credo.exs` uses
  `%{enabled: [...]}` to *replace* the default style checks): UnsafeExec,
  RaiseInsideRescue, OperationOnSameValues, debug leftovers (IoInspect/Dbg/
  IExPry), unused Enum/File/Keyword/List/Path/Regex/String operations, and
  TODO/FIXME hygiene.

## Alternatives considered

- **Dialyzer** — rejected: it duplicates what the built-in checker already
  catches for this codebase, at high setup cost (PLT, success-typing noise).
- **Full Credo (all default checks)** — rejected: the Readability/Design/Refactor
  checks are style; the codebase already passes `mix format`, and those checks
  would add noise without finding bugs.
- **Sobelow** (security) — not adopted; noted as a future option if we add
  routes/DB that warrant it.

## Consequences

- Undefined-function and unused-def regressions fail CI at compile time.
- Credo catches the class the type checker misses (unsafe exec, same-value
  operations, debug leftovers) without style noise.
- The two Credo findings this surfaced (a `raise` that should be `reraise`, an
  `IO.inspect` leftover) were fixed on adoption.
