# 0017. ElementSelect: a creator-plugin feedback channel from UI to agent

- **Status**: accepted
- **Date**: 2026-08-27
- **Deciders**: project author

## Context

The harness's defining feature is authoring plugins at runtime, from inside the
console itself (`define_plugin` / `redefine_plugin` / `save_plugin`). For UI
plugins this feedback is fuzzy: the author points at the screen and says "this
button, move it over there", and the agent has to guess which element, which
plugin, and which file. The reference `agent-browser` solves the same problem
for *external* pages (a Pick toolbar in headed Chrome); the console needed the
equivalent for its *own* UI — a precise pointer from the user's eyes to the
code, captured at pick time.

## Decision

Add a **Pick** seat (`DshBeam.Ui.Panel.ElementSelect`) to the composer toolbar
that turns any click on the console into a structured, agent-readable marker
injected into the composer draft:

```
[요소 지적] button#composer-send .composer-send
슬롯: :composer_toolbar
플러그인: DshBeam.Ui.Panel.Command
소스: lib/dsh/ui/panel/command.ex
셀렉터: form.composer > .composer-actions > button.composer-send
내용: "send"
HTML: <button class="composer-send">send</button>
```

Two pieces make the pointer precise:

1. **Region markers** — `DshBeam.Ui.render_slot/3` wraps every plugin
   contribution in a layout-transparent span (`display: contents`,
   `data-dsh-region*`) carrying the slot name, the plugin module, its source
   file, and the keyed-slot key. The picker reads the closest region via
   `closest('[data-dsh-region]')`, so a marker always names *where* the
   element came from, not just its HTML.
2. **Runtime hooks** — all interactive JS in this package (the picker itself,
   and the workspace row menu) is declared as `data-phx-runtime-hook`, the
   LiveView mechanism that resolves a hook from a `<script>` inside the
   rendered HTML. A plugin therefore ships its own hook without touching the
   shell's static hooks map in `layouts.ex`.

The agent-side contract lives in the plugin's `prompt_section`: how to read a
marker (region → source file → slot owner), where console chrome lives
(`lib/dsh_beam_web/layouts.ex`, `console_live.ex`) vs. plugin panels
(`lib/dsh/ui/panel/*.ex`), and that edits are applied live with
`define_plugin` / `redefine_plugin`.

## Alternatives considered

- **A screenshot / image pick** — rejected for now: the console is a LiveView
  over a text diff; a CSS selector + HTML + region is precise and cheap, and a
  visual crop can be layered on later without changing the marker contract.
- **Hard-coding hook names into `layouts.ex`** — rejected: that is the shell
  edit the plugin model exists to avoid; `data-phx-runtime-hook` resolves the
  hook from the plugin's own markup.
- **Region attribution via CSS classes / naming conventions** — rejected: a
  class tells you the style, not the owner; an explicit `data-dsh-region`
  marker is introspectable and survives refactors.

## Consequences

- Any element of the console is now addressable by the agent in one pick, and
  the follow-up edit request carries its own source pointer.
- The same pattern (region markers + runtime hooks + `prompt_section`) is the
  recipe for future creator-plugin packages; `DshBeam.Ui.Panel.Workspace` uses
  it for the row-click switch and the ⋮ (meatball) close menu.
- The picker's payload is a plain map of strings; growing it (e.g. bounding
  box, `data-phx-*` attrs) is a payload-only change — no shell change.
- Revisit if the console ever renders non-LiveView chrome (a static landing
  page): region markers there would need to be authored by hand.
