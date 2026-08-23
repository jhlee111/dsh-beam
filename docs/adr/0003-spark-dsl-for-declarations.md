# 0003. Spark DSL for plugin declarations

- **Status**: accepted
- **Date**: 2026-08-22
- **Deciders**: project author

## Context

Plugins declare `need`/`provide` (later `setting`, `tool`, `ui_slot`), and the
console must introspect those declarations to render the inventory and settings
UI. We could hand-roll `defmacro` or use a maintained validation/introspection
library.

## Decision

Use **Spark** (`~> 2.6`, the Ash team's DSL engine) for plugin declarations:
`Section`/`Entity`/`Field` with compile-time validation + runtime introspection
via `Spark.Dsl.Extension.get_entities/2`.

## Alternatives considered

- **Hand-rolled `defmacro`** — rejected: reinventing validation and
  introspection for little gain; Spark is maintained and tested.
- **No DSL, plain module attributes** — rejected: attributes give no
  compile-time validation of the declarations' shape.

## Consequences

- Declarations are validated at compile time and introspectable at runtime —
  the substrate for the inventory, settings, and tool/slot registries.
- We inherit Spark's learning curve and its version cadence.
- Undefined-module references break test compilation in Elixir, so development
  had to proceed incrementally (one file + its test at a time).
