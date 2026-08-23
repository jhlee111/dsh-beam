# 0009. Typed settings as a layered store

- **Status**: accepted
- **Date**: 2026-08-22 (wired to live config 2026-08-23)
- **Deciders**: project author

## Context

Plugins need configurable behavior (the shell's timeout, the loop's step cap),
and the console must render per-plugin settings forms. The reference separates
(a) the declared schema, (b) the stored overrides, and (c) credentials.

## Decision

`use DshBeam.Plugin` declares `setting(name, type, default, doc)`; the
`DshBeam.Settings` store holds per-plugin **overrides validated against the
schema**, layered over defaults. `Runtime.start_entry` merges resolved settings
into the mount config, and `Runtime.restart/2` re-mounts a plugin after a
settings save so overrides take effect live. Credentials stay *references*
(ADR-0006), not stored values.

## Alternatives considered

- **Pass config only at mount** — rejected: a console save would never reach
  the running plugin (the actual bug that motivated this ADR).
- **One global settings map** — rejected: per-plugin namespaces keep schemas
  and overrides isolated and introspectable.

## Consequences

- The inventory/settings panel renders any plugin's typed settings without
  per-plugin UI code.
- Settings changes are live reconfiguration (via restart), not re-registration.
- File persistence is deferred; the store is in-memory (future work, modeled on
  the reference `settings-file`).
