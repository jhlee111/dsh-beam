# dsh-beam — a harness for the BEAM

"Everything is a plugin" — a PoC that reproduces the paper (A Programming
Paradigm for Spatiotemporal Composability) on Elixir/OTP: revertible effects,
reactive coeffects, and the L-Unload guard.

Design and test list: [PLAN.md](PLAN.md). Review history and fix plan:
[REVIEW.md](REVIEW.md).

## Running

    mix test

Elixir 1.20.2 / OTP 28 (pinned via .tool-versions for asdf).

## Structure

The layout mirrors the TS harness: a Cordis core (`vendor/cordis`) and the
plugins built on it (`packages/*`).

- lib/dsh/cordis/* — the substrate (= vendor/cordis): Context (unified context,
  bindings + fibers + the pending-unload machine), Effect/Coeffect/Fiber, Loader
  + Runtime (declarative composition + incremental reconfiguration), the
  use DshBeam.Plugin macro + Spark DSL (need/provide/setting/tool) + the
  installed-plugin inventory, Settings (typed overrides) + Credential
  (references, not keys), and the Tool registry.
- lib/dsh/* — the harness plugins (= packages/*): Session (append-only log),
  Llm + Chat, Shell, Sandbox (§6.3 boundary), Creator, Console, and the generic
  Provider/Consumer examples.
- lib/dsh_beam_web/* — the LiveView console (composition, bindings, event feed, chat, plugins, creator/sandbox editor)
- priv/sandbox_runner.exs — the child runtime (compiles and executes sandboxed plugins in their own BEAM)
- test/dsh/* — the TDD suite (one test per paper guarantee)
- reference/deepseek-harness — the TS harness as a git submodule: the read-source for
  porting its modules and UI (when modifying it, work on a branch of that repository)

## Live console

Everything the harness does is visible on one page — a plugin that owns the
Phoenix endpoint, fed by the context/runtime subscription streams:

    DEEPSEEK_API_KEY=sk-... mix run scripts/console.exs   # http://127.0.0.1:4001

The chat pane drives the agent loop (model ↔ bash/fs tools) and renders its
trace; the llm provider talks to real deepseek-chat via the DEEPSEEK_API_KEY
environment variable. Without it the pane reports
{:error, {:missing_env, "DEEPSEEK_API_KEY"}}. The page shows fibers (4 states),
bindings, the event feed, and a creator/sandbox source editor with kill/crash
buttons to watch re-injection and the L-Unload guard live.

## Protocol summary

- Plugins declare dependencies (deps) and provisions (provides) via DshBeam.Context.register.
- Activation: {:dsh_activate, view} / withdrawal: {:dsh_withdraw, keys} -> ack
  {:dsh_deactivated, pid, keys} (or :DOWN, or a timeout).
- Withdrawal removes a binding only after every dependent's teardown completes
  (the L-Unload guard).

## reference/ submodule

`reference/deepseek-harness` is a git submodule pointing at
[jhlee111/deepseek-harness](https://github.com/jhlee111/deepseek-harness). It is
the source read while porting the TS harness's packages/* modules and apps/web
UI to Elixir.

    git submodule update --init            # initialize after cloning
    git -C reference/deepseek-harness pull # track upstream
