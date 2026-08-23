# Architecture

The short version: **everything is a plugin**, and the *substrate* is what makes
that sentence true. This guide explains the substrate, the fiber lifecycle, and
how data flows, so the code is legible. For *why* these choices were made, see
the ADRs.

## The two layers

```
┌────────────────────────────────────────────────────┐
│ harness plugins (lib/dsh/*)                        │
│   Session · Llm · Shell · Sandbox · Creator ·      │
│   Console · Agent.Loop · tools · guards · panels   │
├────────────────────────────────────────────────────┤
│ substrate (lib/dsh/cordis/*)                       │
│   Context · Effect/Coeffect · Fiber · Runtime ·    │
│   use DshBeam.Plugin + Spark DSL · Settings ·      │
│   Credential · Tool registry · UI slot registry    │
└────────────────────────────────────────────────────┘
```

The substrate is not a plugin; it is the premise (ADR-0002). Plugins declare
what they **need** and **provide**; the substrate resolves those into a live
composition.

## A plugin's declaration

```elixir
defmodule MyTool do
  use DshBeam.Plugin

  need :shell                 # a dependency key
  provide :something          # a capability key
  setting :limit, type: :integer, default: 10, doc: "..."
  tool :my_tool, description: "...", parameters: %{}
  ui_slot :panels, kind: :list, order: 10, component: {__MODULE__, :panel, []}

  @impl DshBeam.Plugin
  def handle_dsh_tool_call(:my_tool, args, state), do: {:ok, ...}
end
```

`need`/`provide`/`setting`/`tool`/`ui_slot` are Spark DSL sections, validated at
compile time and introspectable at runtime (the inventory, settings, tool and
slot registries all derive from them).

## The fiber lifecycle

A plugin instance is a **fiber** — a `:gen_statem` process with four states
(ADR-0004):

```
inactive → active → reloading / unloading
```

- **activation** resolves `need`s against the context; a satisfied view becomes
  the fiber's committed view `ω`.
- **withdrawal** runs after every dependent drains (the L-Unload guard), then
  runs the fiber's LIFO inverse effects.
- **reloading** is hot code swap (creator `redefine`), transactional: compile
  first, withdraw, swap, mount, roll back on failure.

The `Context` holds the unified binding map (key → fiber) and the pending-unload
machine. The `Runtime` owns a `DynamicSupervisor` and reconciles a desired
composition (a list of entries) against what is running, with crash re-injection
and backoff.

## Data flow

```
desired composition (entries)
      │  Runtime.reconcile (diff → start/stop/restart)
      ▼
fibers (:gen_statem)  ── provide ──►  Context (key → value)
      │
      ▼
Session (append-only log)  ── projections ──►  chat · todo · model context
```

- The **Session** is the single source of truth (ADR-0005). The loop writes
  `user`/`tool_call`/`tool_result`/`assistant` events; everything else *derives*
  from it.
- The **console** is a plugin that owns the Phoenix endpoint and subscribes to
  the Context/Runtime/Session event streams — it is reactive, not polling.
- The **agent loop** is a plugin (`need :llm, :session`) that discovers tools
  from the Tool registry, dispatches their calls, and answers (multi-turn over
  the session).

## The paper's guarantees, tested

| Guarantee | Where enforced / tested |
|---|---|
| Recovery exactness | `effect_test.exs` — inverses run LIFO, per-fiber |
| L-Unload guard | `withdraw_test.exs`, `intercept_test.exs` |
| Confluence | `context_test.exs` (path-independent quiescent state) |
| Fault isolation | `runtime_test.exs` (crash → re-injection, siblings live) |
| §6.2 cross-node | `dist_test.exs` |
| §6.3 boundary | `sandbox_test.exs` |

For the *finding* these tests produced (where OTP isolation and the paper's
fine-grained model reinforce vs collide), read [PLAN §22](../../PLAN.md#22-conclusion--where-the-two-reinforce-and-where-they-collide).
