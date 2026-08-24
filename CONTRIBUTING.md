# Contributing

Thanks for your interest in dsh-beam. **Everything is a plugin** — so most
contributions are "add a plugin", whether that's a tool, a UI panel, a
capability, or a safety guard. Panels register into `ui_slot`s; the shell is
never edited.

## Getting started

```bash
git submodule update --init
mix deps.get
mix test          # 148 tests, one per paper guarantee
```

The full guide is in [docs/guide/contributing.md](docs/guide/contributing.md) —
workflow, plugin/tool/panel/ADR recipes, style, and CI. Read it first.

## Where to help

The README's [Roadmap](README.md#roadmap--not-yet-done) lists what is not done
yet. Good starting points:

- **Session persistence** — a `DshBeam.Session.File` (JSONL) provider already
  exists but is not wired up; wire it into `Workspace.open_session` and restore
  the workspace roster on boot.
- **Redefine in the UI** — `redefine_plugin` is now a tool, but the Creator
  settings panel still only exposes `define`; add a redefine affordance there.
- **More tools** — web search, a subagent capability, etc. Each is just a tool
  plugin (`use DshBeam.Plugin` + `tool/3` + `handle_dsh_tool_call/3`).
- **Richer conversation nodes** — port retry / compaction / reasoning rows from
  the reference (`reference/deepseek-harness` submodule).
- **Plugin prompt sections** — any new capability should also declare a
  `prompt_section` so the model knows how to use it.

## Plugin wish list

Plugins we'd love someone to write (roughly in priority order). Each is just a
plugin (`use DshBeam.Plugin` + `tool/3` / `ui_slot` / `need`/`provide`):

- **Guard rail / approval** — confirm before destructive or self-modifying
  actions (`define_plugin`, `redefine_plugin`, arbitrary `bash`). **The top
  ask**, given "use at your own risk" (see the README).
- **Permission presets** — per-tool allow/deny lists (the reference's
  `permission-presets`).
- **Web search** — a search + fetch capability (a tool plugin).
- **Subagent** — delegate a task to a sub-agent (a capability + tool).
- **Persistent terminal** — a long-lived shell session instead of one-shot bash.
- **Compaction** — summarize older turns to bound context.
- **Skill registry** — a named skill catalog + loader tool.
- **Hook bridge** — Claude Code / Codex hook integration.

## Workflow

1. Open (or pick) an issue describing the gap.
2. Branch, then write the failing test first (`test/dsh/<area>_test.exs`).
3. Implement in `lib/dsh/...`.
4. Run the four gates locally:
   ```bash
   mix format --check-formatted
   mix compile --warnings-as-errors
   mix credo --strict
   mix test
   ```
5. Open a PR — CI runs the same gates.

## Notes

- The TypeScript harness the web UI is ported from lives in
  `reference/deepseek-harness` (a git submodule); read it before porting more UI.
- Keep the "everything is a plugin" shape: add plugins, never edit the shell.
- Non-obvious decisions get an ADR (`docs/adr/`).
