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

- lib/dsh/context.ex — the unified context (bindings + fibers + the pending-unload machine)
- lib/dsh/plugin.ex — the use DshBeam.Plugin macro (activation/withdrawal/termination protocol)
- lib/dsh/effect.ex · coeffect.ex · fiber.ex — the substrate primitives
- lib/dsh/loader.ex · runtime.ex — declarative composition + incremental reconfiguration
- lib/dsh/session.ex + session/* — the first plugin: an append-only session log
- lib/dsh/creator.ex — creator mode: runtime code loading + transactional hot replacement
- lib/dsh/sandbox.ex + sandbox/plugin.ex — the §6.3 execution boundary: untrusted source runs in a child OS process
- priv/sandbox_runner.exs — the child runtime (compiles and executes sandboxed plugins in their own BEAM)
- test/dsh/* — the TDD suite (one test per paper guarantee)
- reference/deepseek-harness — the TS harness as a git submodule: the read-source for
  porting its modules and UI (when modifying it, work on a branch of that repository)

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
