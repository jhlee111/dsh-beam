# 0013. UI slots: a UI panel is a plugin

- **Status**: accepted
- **Date**: 2026-08-23
- **Deciders**: project author

## Context

The console was a single LiveView with hard-coded sections (composition, chat,
todo, settings, plugins). To keep "everything is a plugin" true at the UI
layer, a panel should be *registered* by a plugin, not baked into the layout —
this is the reference's `ui-slots` SlotMap idea.

## Decision

Add a **`ui_slot` DSL** (`name`/`kind`/`scope`/`component`/`order`/`key`/
`select`) to `use DshBeam.Plugin`, introspect it via `DshBeam.Plugin.slots/1`,
catalog contributions in `DshBeam.Ui.Registry`, and compose them with
`DshBeam.Ui.render_slot/3`. Kinds mirror the reference: `single` (lowest order),
`list` (ordered), `keyed` (key dispatch), `chain` (first matching `select`).

## Alternatives considered

- **Hard-coded sections** — rejected: no way to add/remove a panel as a plugin.
- **Phoenix.Component `slot`** — rejected: that macro is for HEEx *component*
  slots, not a runtime registry; our DSL is named `ui_slot` to avoid the clash.
- **React `ui-slots` port** — rejected (see ADR-0010).

## Consequences

- A panel is a plugin: adding one is `use DshBeam.Plugin` + `ui_slot(...)`.
- The registry is introspectable (like the tool registry), so the console can
  list *which* plugins contribute *which* panels.
- The console's built-in panels (composition, bindings, chat, todo, llm
  settings, creator, event feed, plugins) are now `DshBeam.Ui.Panel.*` plugins,
  and the console layout is a single `DshBeam.Ui.render_slot(:panels, assigns)`
  call — adding or removing a panel is adding or removing a plugin, not editing
  the layout.
