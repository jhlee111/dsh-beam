# dsh-beam — a harness for the BEAM

"Everything is a plugin" — a PoC that reproduces the paper (*A Programming
Paradigm for Spatiotemporal Composability*) on Elixir/OTP: revertible effects,
reactive coeffects, and the L-Unload guard.

A plugin is the unit of everything — a tool, a UI panel, a safety guard, a
capability — and the substrate makes them compose, swap, and roll back.

## Origins

The idea and the plugin architecture are not ours. They come from two sources
this PoC re-implements on Elixir/OTP:

- **[DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)** — the
  open-source TypeScript agent harness by [DeepSeek AI](https://deepseek.com),
  where *everything is a plugin*.
- **[_A Programming Paradigm for Spatiotemporal Composability_](https://github.com/cordiverse/paper)**
  — the paper behind [Cordis](https://github.com/cordiverse/cordis), the
  substrate the harness is built on (revertible effects + reactive coeffects).

`dsh-beam` is an independent Elixir/OTP re-implementation for study. The TS
harness it is ported from lives in `reference/deepseek-harness` (a git
submodule).

> ## ⚠️ USE AT YOUR OWN RISK
>
> There are **no guard rails yet** — no approval, permission, or confirmation
> plugins. `define_plugin` / `redefine_plugin` and `bash` run trusted code
> **in-process** and can do anything the process can. Want to fix that? A
> **guard rail plugin** is the top item on the
> [plugin wish list](CONTRIBUTING.md#plugin-wish-list).

## Quick start

```bash
git submodule update --init
mix deps.get
mix test                              # 150 tests, one per paper guarantee

DEEPSEEK_API_KEY=sk-... mix console   # http://127.0.0.1:4888
```

`mix console` is an alias for `mix run scripts/console.exs` — the live console
demo. It serves on **`127.0.0.1:4888`** by default. If another dev server is
already on that port, pick a free one without touching the config:

```bash
DSH_BEAM_PORT=5000 mix console        # http://127.0.0.1:5000
```

Elixir 1.20.2 / OTP 28 (pinned via `.tool-versions`).

## Documentation

Start here, then follow the links:

- **[docs/guide](docs/guide/README.md)** — onboarding, architecture,
  contributing, glossary.
- **[docs/adr](docs/adr/README.md)** — architecture decision records: *why* each
  choice was made, and its alternatives.
- **[PLAN.md](PLAN.md)** — the research question, the OTP mapping, the milestone
  history, and the conclusion (where OTP isolation and the paper's model
  reinforce vs collide).
- **[CONTRIBUTING.md](CONTRIBUTING.md)** — how to contribute, and where to help
  (the roadmap items as starting points).
- **[REVIEW.md](REVIEW.md)** — the review history and fix log.

## What's inside

```
lib/dsh/cordis/*    the substrate (= vendor/cordis): Context, Effect/Coeffect,
                    Fiber, Runtime, use DshBeam.Plugin + Spark DSL,
                    Settings/Credential, Tool + UI slot registries
lib/dsh/*           the harness plugins (= packages/*): Session, Llm, Shell,
                    Sandbox, Creator, Console, Agent.Loop, tools, guards
lib/dsh_beam_web/*  the LiveView console
priv/static/assets/ vendored LiveView JS + the DSH design tokens (CSS)
priv/sandbox_runner.exs  child runtime for sandboxed plugins
scripts/            demo entrypoints
test/dsh/*          the TDD suite
docs/               guides + ADRs
reference/          the TS harness as a git submodule (porting source)
```

## The console

The console now mirrors the reference DeepSeek Harness web UI, built entirely
as `ui_slot` plugins (panels register into slots — the shell never edits them):

- **Three-column shell** — sidebar | conversation | details, dark theme
  (`body[data-ds-dark-theme]`), a collapsible sidebar (280px ↔ 56px rail), and
  **draggable sidebar and details resize** handles.
- **Workspace sidebar** — a server-side folder picker (browse the filesystem),
  session list with a subtle current-indicator dot, folder-name titles, and
  wrapping paths. Sessions open any folder: a `git worktree` when possible,
  **in-place otherwise** (no `:not_a_git_repo` refusal).
- **Conversation** — Chat / Trajectory tabs; user bubble, assistant **markdown**
  (Earmark), terminal-style **tool cards** (bash command verbatim), role icons,
  the "Deep diving…" turn status + elapsed clock, **back-to-bottom** + stream
  follow, and an **auto-growing composer** with an in-card send/**stop** — the
  stop is a cooperative cancellation token (`DshBeam.Agent.Cancel`) that halts
  the loop at its next step boundary and aborts an in-flight model call. Chat
  is gated on an active workspace session.
- **Settings modal** — Models (provider card + API-key form), Plugins
  (configurable accordion cards), Agent presets (Demo/Agent/Chat, set-default /
  apply / duplicate / delete), General (default preset + workspace root), plus
  Composition / Bindings / Events / Creator (define + export plugin).

### Self-modification

The agent loop can author and reuse plugins from inside any workspace:
`define_plugin` compiles + mounts a plugin live (in-process), and `save_plugin`
persists its source to `~/.dsh/plugins`, which the console **loads on boot** —
so a plugin made in one project is available in every other.

### System prompt as a plugin registry

A `prompt_section` DSL lets any plugin contribute its own guidance; the agent
loop assembles the model-facing prompt from the harness identity + persona +
every plugin's sections (the reference's `SystemPrompt` registry), instead of a
hardcoded one-liner.

## Roadmap — not yet done

The full console-vs-reference gap list lives in
**[docs/ui-gap-review.md](docs/ui-gap-review.md)**. The remaining items:

- **Custom agent-preset persistence** — only the `default_preset` survives a
  restart; duplicated presets are in-memory.
- **Richer conversation nodes** — retry and compaction from the reference are
  not ported; assistant markdown has no syntax highlighting. (Reasoning rows
  are done.)
- **More tools** — bash / fs / todo / calc (plus the self-modification tools);
  no web search or subagent capability yet.
- **Redefine in the UI** — `redefine_plugin` is now a tool, but the Creator
  settings panel still only exposes `define`.
- **Guard rails** — none yet: no approval/permission plugin. See the
  [plugin wish list](CONTRIBUTING.md#plugin-wish-list).

## reference/ submodule

`reference/deepseek-harness` points at
[jhlee111/deepseek-harness](https://github.com/jhlee111/deepseek-harness) — the
source read while porting its `packages/*` modules and `apps/web` UI. Work on a
branch of that repository when modifying it.

```bash
git submodule update --init
git -C reference/deepseek-harness pull
```
