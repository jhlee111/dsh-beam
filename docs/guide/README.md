# Developer guide

Everything you need to understand *why* dsh-beam is shaped the way it is, and
how to work in it. Read in order on first landing.

## Where to start

1. [README](../../README.md) — what this is, how to run it.
2. [PLAN.md](../../PLAN.md) — the research question (§1), the OTP mapping (§3),
   and the milestone history (§11 onward).
3. [ADR index](../adr/README.md) — the decisions and their reasons, in the order
   they were made.
4. This guide.

## Contents

- [Onboarding](onboarding.md) — clone, deps, run, test, the demo.
- [Architecture](architecture.md) — the substrate/plugin split, the fiber
  lifecycle, and how data flows.
- [Contributing](contributing.md) — how to add a plugin, a tool, a UI panel;
  the CI gates and commit style.
- [Glossary](glossary.md) — the vocabulary (fiber, coeffect, revertible effect,
  L-Unload guard, intercept, slot, projection).

## Repository layout

```
lib/dsh/cordis/*    the substrate (Context, Effect/Coeffect/Fiber, Runtime,
                    use DshBeam.Plugin + Spark DSL, Settings/Credential,
                    Tool registry, UI slot registry)
lib/dsh/*           the harness plugins (Session, Llm, Shell, Sandbox, Creator,
                    Console, Agent.Loop, tools, guards)
lib/dsh_beam_web/*  the LiveView console
priv/static/assets/ vendored JS (phoenix/live_view) + DSH design tokens (CSS)
priv/sandbox_runner.exs  the child runtime for sandboxed plugins
scripts/            demo entrypoints (console.exs, agent_demo.exs)
test/dsh/*          the TDD suite (one test per paper guarantee)
docs/adr/           architecture decision records
docs/guide/         this guide
reference/          the TS harness, as a git submodule (porting source)
```

## Language and tone

- **English only** in the repository (README, docs, commit messages, code
  comments).
- Commit messages: conventional, lowercase subject, imperative mood.
- Docs record *why*, not just *what* — point to the ADR when a decision is
  non-obvious.
