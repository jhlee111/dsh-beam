# dsh-beam — a harness for the BEAM

"Everything is a plugin" — a PoC that reproduces the paper (*A Programming
Paradigm for Spatiotemporal Composability*) on Elixir/OTP: revertible effects,
reactive coeffects, and the L-Unload guard.

A plugin is the unit of everything — a tool, a UI panel, a safety guard, a
capability — and the substrate makes them compose, swap, and roll back.

## Quick start

```bash
git submodule update --init
mix deps.get
mix test                              # 120+ tests, one per paper guarantee

DEEPSEEK_API_KEY=sk-... mix run scripts/console.exs   # http://127.0.0.1:4001
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

One page shows the whole harness: the composition (fiber states, restarts,
kill/crash), bindings, the event feed, the chat pane (agent loop, multi-turn,
real-time tool trace), the todo panel (the agent's plan as a session
projection), the llm settings, the plugin inventory, and a creator/sandbox
editor with **export plugin (.exs)** — an edited plugin becomes a deployable
script.

## reference/ submodule

`reference/deepseek-harness` points at
[jhlee111/deepseek-harness](https://github.com/jhlee111/deepseek-harness) — the
source read while porting its `packages/*` modules and `apps/web` UI. Work on a
branch of that repository when modifying it.

```bash
git submodule update --init
git -C reference/deepseek-harness pull
```
