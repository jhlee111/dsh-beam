# Elixir Harness PoC — Plan

> The idea is inherited, the ecosystem starts anew. A PoC that reproduces on Elixir/OTP the
> "everything is a plugin" philosophy of DeepSeek Harness — more precisely its theoretical
> basis, the **spatiotemporal composability** paradigm. Milestone 1 is complete: implementation,
> independent review, and fixes (§11).

## 1. The question to verify (a single one)

When Cordis's precise model — **revertible effect + reactive coeffect** — is implemented on top of
OTP's coarse but strong **process isolation/supervision**, where do the two reinforce each other and
where do they collide?

## 2. Theoretical background (summary of paper.pdf)

"A Programming Paradigm for Spatiotemporal Composability" (Shi, Zhang, Cui; PKU / DeepSeek-AI, 88 pages)
decomposes dynamic composition into two orthogonal dimensions.

- **Temporal composition** — complete rollback of side effects on removal.
  **Revertible effect**: pair every context transformation Γ→Γ with an inverse, and the runtime tracks
  the inverses in a LIFO accumulator (the twisted composition monoid 𝔗Γ). track/recover.
- **Spatial composition** — declarative, reactive management of dependencies.
  **Reactive coeffect**: a component declares a set of dependency keys d, and on context changes it is
  notified as activate/deactivate/neutral.
- **Unified context** — the effect context and the coeffect context unified into a single context type Γ.
- **Dynamic composition calculus** — component → fiber (instance). Lifecycle Θ = INACTIVE/ACTIVE/RELOADING/UNLOADING.
  Rules: O-Insert/Retire/Remove (orchestration), L-Begin/Iter/Finish (activation), L-Divert/Raise (early termination),
  L-Leave/Unload (deactivation).

Guarantees to inherit (metatheory):

1. **Recovery exactness** — running a fiber's accumulator removes only that fiber's contributions and nothing
   else (under the pairwise-independence premise).
2. **L-Unload guard** — a provider's withdrawal runs only after every consumer that resolved it is deactivated
   (dependency-order alignment, no deadlock).
3. **Confluence** — the quiescent state is a function of the final configuration alone (reconfiguration order irrelevant).
4. **Fault isolation** — a failure recovers its effects via UNLOADING and is recorded per fiber (siblings keep running).

## 3. OTP mapping (the intellectual core of this PoC)

| paper | Elixir/OTP reproduction |
|---|---|
| Revertible effect Γ→Γ×(Γ→Γ) | a function returning the inverse as a closure `{new_state, inverse_fun}` (closures are first-class) |
| LIFO accumulator | a list of inverse closures, applied in reverse order on teardown |
| Effect independence (commutativity) | process isolation: separate processes share no state → commutativity is trivial. Shared state (ETS) is a separate discipline |
| Coeffect declaration d | the key list a plugin declares; resolved from the Registry/store |
| Reactive notification | Registry.register/subscribe + child restart on dependency change |
| Fiber lifecycle | a 3-state Context map record (inactive/active/unloading) + the pending-unload machine — promotion to a :gen_statem process is milestone 2 |
| committed view ω | `%{key => pid | module}` in GenServer state |
| L-Unload guard (¬relied) | monitoring consumer processes; run inverses after all are deactivated |
| O-Insert/Retire/Remove | DynamicSupervisor.start_child/terminate_child/delete_child |
| Reconfiguration | config entry diff → child start/stop/update |
| HMR (transactional reload) | the BEAM code server (:code, Code.compile_string) + hot swap — more native than Node |
| Sandbox (execution boundary) | running untrusted code under supervision in a Port/subprocess (a different runtime) — §6.3 requires exactly this design |
| Cross-process calls | :erlang.dist + GenServer.call/:rpc — §6.2 |
| Access control (inject = capability) | behaviour + Registry mediation; interception = wrapping the provider |

**Central design tension (the object of inquiry)**: the paper models *fine-grained effect tracking inside a fiber*,
but OTP's isolation/supervision unit is the *process*, which is coarser. The PoC will answer — reproducing the
fine-grained accumulator as Elixir closures, whether OTP supervision overlaps on top of it as a coarse safety net,
and whether that overlap is reinforcement or collision.

## 4. Substrate design

The metaframework (corresponding to the Cordis core) that makes "everything is a plugin" true. Not a plugin but a premise.

- DshBeam.Context — the unified effect/coeffect context.
- DshBeam.Effect — ctx.effect(fn -> ... {value, inverse} end); inverse accumulation, LIFO dispose.
- DshBeam.Coeffect — key declaration d + resolution + change notification.
- DshBeam.Fiber — a 3-state map record; the L-Unload guard is implemented by the Context's pending-unload machine
  (asynchronous, dependent ack/DOWN/timeout).
- DshBeam.Loader — a declarative list of entries (id/url/isolate/config/disabled) + incremental reconfiguration.

## 5. Milestone 1: the first plugin — Session (append-only log)

**Rationale**: in DSH the session log is the "single source of truth", and everything (model-visible ⟺ logged)
is derived from it. At the same time this one plugin demonstrates both mechanisms.

- **Effect**: appending events (inverse = truncate/restore after that sequence).
- **Coeffect**: a projection/consumer declares :session → when the provider goes down the consumer deactivates first.
- **Provider swap**: swapping the in-memory (ETS) ↔ persisted (file) provider = reconfiguration.

## 6. Verification criteria (the definition of milestone 1 completion)

1. The runtime boots from an ordered plugin list.
2. The Session provider mounts → a consumer resolves :session → append/read work.
3. Provider unload → the consumer deactivates first → the provider's effects recover in reverse order → the context
   returns to its prior state (recovery exactness).
4. A provider swap reactivates only the consumer (siblings unaffected).
5. 1–4 verified automatically via mix test.

## 7. The hard parts the paper answers in advance

- **Sandbox (§6.3)** — language-level access control is powerless against malicious code; an execution boundary
  (a separate runtime / sandbox process / container) is needed.
  → Untrusted plugins run in a subprocess runtime outside the BEAM. (matches the user's proposal; theoretical
  grounding secured)
- **Language independence (§6.4)** — temporal composition via closures + a runtime module registry, spatial composition
  via typed DI + dynamic mediation.
  Elixir: closures ✓, the :code module registry ✓ (superior to Node), typed DI *partially* satisfied via behaviour +
  Registry + 1.20 types (the lack of a dynamic Proxy is a weakness).
- **System boundary (§6.1)** — operations on external locations (file writes, the network) are treated as idΓ and cannot
  be tracked or recovered; recovery is withholding or compensation.
  → Persisting the session log is "outside the boundary", so it needs a separate recovery strategy.
- **Dependency types/versioning (§6.6)** — nominal key collisions/drift. The PoC avoids this via namespacing; structural
  compatibility is a non-goal.

## 8. Non-goals

- Reproducing the TS harness's SDK projection/type graph.
- LLM adapters, agent loops, tool pipelines (later milestones).
- Compatibility with a third-party plugin ecosystem.
- Windows support.

## 9. Directory

An independent repository jhlee111/dsh-beam — a Mix project dsh_beam.
Elixir 1.20.2 / Erlang 28.4.3 pinned in .tool-versions.

## 10. TDD test list (the milestone 1 execution spec)

Write tests first with ExUnit, then make them green with the implementation. Each test pins one guarantee from the paper.

| Increment | Test | Guarantee pinned |
|---|---|---|
| 1. Effect | dispose applies inverses LIFO | recovery order (§3.1, recoverΓ) |
| 1. Effect | each inverse reverts only its own step | composition of inverses |
| 1. Coeffect | satisfied when all declared keys are provided | spatial composition (§3.2) |
| 1. Coeffect | reports missing keys | unsatisfied |
| 1. Coeffect | the view contains only the declared keys | committed view |
| 2. Session | Memory: seq assignment · ordered reads · count | first-plugin behavior |
| 2. Session | File: persists across restart (JSONL) | persistence boundary (§6.1) |
| 3. Context | unload recovers only the owner's contributions | recovery exactness (Thm 61/62) |
| 3. Context | dependents activate when a key appears | reactive coeffect |
| 3. Context | dependent deactivation precedes withdrawal | L-Unload guard (Thm 63) |
| 3. Context | the committed view holds during teardown | the guard's substance |
| 3. Context | binding withdrawal on owner death | OTP safety net |
| 3. Context | rejects duplicate keys | exclusive binding (§6.2) |
| 4. Runtime | boots an ordered composition · uses session | composition |
| 4. Runtime | guard ordering on provider removal | reconfiguration |
| 4. Runtime | a provider swap reactivates only dependents | swap + confluence (Thm 73) |
| 4. Runtime | reading the session during teardown (probe) | the guard's substance |
| M2. DSL | needs/provides declarations validated · introspected via Spark | the encoding of paper Def 44 (d, p) |
| M2. DSL | the composition DSL (entry) passes the milestone 1 tests unchanged | the encoding of Def 74 + the regression net |

**Milestone 2 — the Spark DSL front.** The paper's declarations (a component's d/p, an entry's
id/url/isolate/config/disabled) are in effect DSL syntax. Using Spark's (Ash team, v2.6) section/entity/option
validation + introspection, write `use DshBeam.Plugin` (needs/provides) and `use DshBeam.Composition` (entry).
Benefits: (1) compile-time validation of declarations, (2) `Spark.Dsl.Extension` introspection as the substrate
for cordis_inspect/creator mode, (3) entry schema validation as the premise of Loader.diff. **Order**: pin down the
runtime semantics (the interpreter) first with increments 1–4, then layer the DSL on top — the DSL's observable
behavior is nothing but that semantics, and the existing tests become the regression net. Hand-rolling defmacro is
possible, but we use the maintained Spark to avoid reinventing validation and introspection.

Note: since undefined module references break test compilation in Elixir, proceed incrementally (one test file +
implementation) rather than writing the whole red suite at once.

## 11. Progress status

- [x] Increments 1–4: substrate + Session + Runtime — milestone 1 implementation complete
- [x] 2 independent reviews (A: official Elixir docs, B: correctness · concurrency) — merged into REVIEW.md
- [x] P1 register-fiber merge (H3) / P2 C' asynchronous withdrawal protocol + use DshBeam.Plugin (B-H1/B-H2) / P3
  Runtime failure reporting · re-injection (A-H2) / P5 hygiene
- [x] P4 aligned this document with the implementation state (explicit 3-state reduced model)
- [x] Milestone 2-①: promoted the fiber to a 4-state :gen_statem process — 23 passed
- [x] Milestone 2-②: crash-path committed view (ordered shutdown) — 24 passed, 0 failures across 25 seeds
- [x] Milestone 2-③: confluence concurrency verification — 27 passed (path-independent quiescent state · concurrent
  reconcile · concurrent use during swap)
- [x] Milestone 2-④: Spark DSL front — 30 passed (need/provide declarations, composition DSL, 27-test regression net maintained)
- [x] Known-limitations backlog: crash re-injection gained backoff + withdrawal-race retries and a kill/crash
  distinction, and reconcile now re-asserts every desired non-running entry (convergence) — 35 passed
- [x] Known-limitations backlog: §6.3 execution boundary implemented (DshBeam.Sandbox) — untrusted source compiles
  and runs in a child OS process with its own BEAM; crash → guard → re-injection crosses the boundary — 40 passed

## 14. Milestone 4 — LLM provider plugin + live web console (complete)

- LLM capability: DshBeam.Llm.Plugin provides :llm (OpenAI-compatible
  /chat/completions, deepseek-chat and peers) with a swappable adapter
  (provider-swap pattern; a :plug replaces the transport for offline tests).
  DshBeam.Llm.Chat declares :session + :llm and appends user/assistant turns.
- Subscriber streams: Context.subscribe / Runtime.subscribe fan out state
  and entry changes to observers; dead subscribers are cleaned up.
- The UI is a plugin: DshBeam.Console owns the Phoenix endpoint (started
  unlinked, stopped synchronously on withdrawal), and the LiveView reads the
  composition and chat through the subscription streams.
- Tests: llm (4), subscribe (4), console LiveView (6: render/seed, chat loop,
  creator define, sandbox define, kill-via-event-stream, crash-child
  re-injection) — 54 passed, stable across seeds.

## 13. Milestone 3 — creator mode (complete)

DshBeam.Creator: load a source string via Code.compile_string -> the BEAM :code server -> mount as a fiber.
redefine is the transactional HMR of paper §5.2.2 (compile first -> withdraw through the guard -> swap the code ->
roll back on failure). define is transactional too: a failed mount rolls the composition back.
3 tests (define/redefine/undefine stories, mount-crash isolation, syntax-error no-change) — 33 passed.

The §6.3 execution boundary for untrusted source lives in DshBeam.Sandbox (child OS process + line-JSON
protocol + DshBeam.Sandbox.Plugin guardian fiber); see REVIEW.md for the boundary rules.

## 12. Milestone 2 (candidate)

- Promoting the fiber to a :gen_statem process (4 states) — actually demonstrating the paper's "fine-grained
  accumulator vs process isolation" tension
- Guaranteeing the committed view on the crash path (ordered shutdown: a provider's resources survive its dependents'
  teardown)
- Concurrency verification of confluence (reconfiguration order irrelevant)
- Spark DSL front: use DshBeam.Plugin's needs/provides + the composition DSL (entry)

## 15. "Everything is a plugin" — the inventory + typed settings substrate (complete)

The original harness's design is not the LLM/chat/loop framework (those exist
everywhere); it is that EVERYTHING — shell limits, web search, storage,
tools, UI panels, policies — is a plugin with typed settings and an inventory.
Expressed here as:

- `setting` declarations in use DshBeam.Plugin (name/type/default/doc, Spark
  validated + introspectable) — the per-plugin typed settings schema.
- DshBeam.Plugin.Inventory — the installed-plugin catalog (list + settings).
- DshBeam.Settings — per-plugin overrides validated against the schema, layered
  over defaults; credentials are references, never stored values.
- The console's plugins panel — the inventory list (enabled/disabled) with
  per-plugin typed forms and Save.

LLM stays an example plugin: DshBeam.Credential (config carries a name, not a
literal key) + configure/2 (adapter re-resolves per request — reconfiguration
without re-mount) mirror the harness's credential/settings separation.

## 16. Milestone 6 — breadth: a non-LLM capability (shell) (complete)

The design is not LLM-specific. DshBeam.Shell.Plugin provides :shell with the
original harness's Shell settings (command_timeout_ms, output_cap_bytes) —
visible in the inventory/settings panel — and run/3 executes in a subprocess
with a timeout and output cap. DshBeam.Shell.Consumer declares :shell and
deactivates first when the provider withdraws (the guard across a non-LLM
capability). 77 tests.

## 17. Milestone 7 — the MVP: tools are plugins, the loop is a plugin (complete)

The harness "runs" when the model↔tool loop works on the substrate. A tool is
a plugin (`tool` DSL → default mount binds the name; handle_dsh_tool_call
answers {:tool_call, ...}); the agent loop is a plugin (`need :llm, :session`)
that discovers tools from the registry, dispatches their calls, and answers.
tool-bash (needs :shell) and tool-fs (workspace root, path containment) are the
first tools. The LLM result now carries tool_calls + finish_reason. 85 tests.

## 18. Milestone 8 — intercept (access control = provider wrapping) (complete)

Cordis's `intercept` (inject=capability, interception=provider wrapping): a
`need` may declare an intercept ({M, f, args}) that wraps the resolved value
for that fiber only. The same provider resolves to different views per
consumer; a swap re-applies the intercept; the intercepted consumer is still a
dependent. 88 tests.

## 19. Milestone 9 — §6.2 cross-node composition (complete)

The last mapping-table row: a fiber can live on another BEAM node and register
with a local context. The context's monitor, activation messages, and the
L-Unload guard all cross :erlang.dist — a remote owner is just {pid, node}
(DshBeam.Dist, DshBeam.Pid). Guard + crash safety net hold across nodes.
91 tests. (Requires epmd + ~/.erlang.cookie; the tests skip without them.)

## 20. Milestone 10 — MVP web UI (complete)

The console's chat pane now drives the agent loop and renders its step trace
chronologically (task → tool call → result → answer); the seed mounts the full
agent composition. Agent.Loop gained run_trace/2. 93 tests. A cleanup pass
grouped the substrate modules, removed a crash dump, and boots the console demo
with the full composition.

## 21. Milestone 11 — web console stabilization (complete)

The hand-wired Phoenix/LiveView layer had three gaps that only surfaced when
driving the real model path in the browser; each is now fixed with a regression
test where the seam was testable.

- **LiveView client was never loaded.** The layout omitted phoenix.js /
  phoenix_live_view.js and the LiveSocket connect, so the browser never opened
  /live. Every `phx-submit` fell back to a plain HTML GET (`/?text=hello`),
  which both dropped the event and leaked the literal API key into the URL.
  The endpoint now serves vendored bundles via `Plug.Static` and the layout
  connects the socket with the CSRF token.
- **secret_key_base too short.** Plug.Session's cookie store requires ≥64 bytes;
  the previous hand-written value was 44, so the first render that stored the
  CSRF token crashed. Replaced with a `mix phx.gen.secret` value.
- **Req adapter read `tools` as a map.** `chat/3` passes a keyword list
  `[tools: ...]`; the adapter used the map-only `opts.tools` and raised
  `BadMapError`, crashing the llm fiber on the first real tool-armed call.
  Now `opts[:tools]`; a regression test drives `chat/3` + tools through the
  mock plug and asserts the JSON body.
- The agent loop now runs off the LiveView process (a `Task` + `handle_info`
  result message), so the real model round-trip no longer freezes the pane.
- Code reloading is disabled: Phoenix 1.8's CodeReloader cannot survive a
  config change or a mid-edit compile error, and a poisoned VM is worse than an
  explicit restart. 95 tests.

## 22. Conclusion — where the two reinforce, and where they collide

The PoC set out to answer one question (§1): when the paper's precise model —
revertible effect + reactive coeffect — is implemented on OTP's coarse but
strong process isolation/supervision, where do the two **reinforce** and where
do they **collide**? After milestones 1–11, the answer is concrete.

### Where they reinforce

1. **Commutativity for free.** Recovery exactness presupposes that effects are
   pairwise-independent so inverses can run in LIFO order. OTP process isolation
   *is* that independence: separate processes share no state, so the premise the
   paper has to *assume* is *given* by the substrate. The accumulator stays a
   list of closures; nothing in it has to prove non-interference.
2. **Supervision as the coarse safety net over the fine-grained accumulator.**
   The paper's recoverable-effect machinery and OTP's restart machinery are not
   the same layer and do not fight: the fiber's inverse list is the *semantic*
   rollback (exact, per-fiber), while `DynamicSupervisor` + backoff re-injection
   is the *availability* safety net (coarse, best-effort). A crash unwinds
   through the guard, then a fresh fiber is re-injected — the two overlap rather
   than collide.
3. **The guard maps cleanly to monitors.** The L-Unload guard ("a provider
   withdraws only after every consumer is deactivated") is a dependency order
   that OTP's monitor/`DOWN` primitive expresses directly; the pending-unload
   machine rides `Process.monitor` and needs no extra bookkeeping.

### Where they collide

1. **The unit of composition does not match the unit of isolation.** The paper
   tracks effects *inside* a fiber (an internal accumulator), but OTP's atomic
   unit is the *process*; a fiber's in-process accumulator is torn down by a
   kill before it can run its inverses, so "recovery exactness on the crash
   path" is only as good as the ordering that survives. The PoC had to add the
   committed view + ordered shutdown (milestone 2-②) precisely to bridge this —
   evidence of the collision, resolved by more machinery.
2. **Synchronous `call` reentrancy vs the async ack protocol.** The paper's
   activation/deactivation is asynchronous with acks; OTP's `GenServer.call` is
   synchronous. The unload path's `:gen_statem.call` into a consumer can
   re-enter the context and deadlock (REVIEW H1). The substrate works around it
   by making withdrawal message-driven — the collision is a recurring trap, not
   a one-off.
3. **Fine-grained coeffect reactivity has no native substrate.** The paper
   notifies dependents of *arbitrary context keys* changing; OTP gives process
   exit signals but not key-level change notifications, so the reactive-coeffect
   layer is hand-built (subscription streams, `activate`/`deactivate` messages)
   on top of the substrate — a genuinely new mechanism, not a reuse of OTP.
4. **The HMR/reload boundary.** The paper's transactional reload presumes a
   runtime that can swap code atomically; the BEAM can (code server), but the
   *web* layer around it (Phoenix's code reloader) cannot survive a config
   change or a mid-edit error — milestone 11 disabled it for stability. The
   boundary between "BEAM-native reload" and "framework reload" is where the
   two paradigms stop cooperating.

### Bottom line

The two reinforce at the **effect/rollback** layer (isolation gives the
independence the paper needs) and collide at the **lifecycle/notification**
layer (the fiber is a finer unit than a process; synchronous calls and
key-level reactivity have to be hand-built). The PoC's contribution is making
that boundary explicit: revertible effects port cleanly onto OTP, reactive
coeffects and the guard do not — they are the parts that had to be invented
afresh.

## 23. Milestone 12 — toward a usable harness (complete)

After the conclusion, the console is pushed from a design PoC into a harness
you can actually drive, closing the feature gap to the reference webui while
keeping the "everything is a plugin" substrate intact:

- **Multi-turn agent loop** — `Agent.Loop.run/2` replays prior user/assistant
  turns from the session into the model context (a conversation, not a
  stateless one-shot).
- **Session as the chat pane's single source of truth** — the loop records each
  turn chronologically (user → tool_call → tool_result → assistant, or error);
  the chat pane derives its rows from `Session.all/1`, so a page refresh keeps
  the conversation and tool execution is visible; `Session.clear/1` ("new
  conversation") truncates the log.
- **Session is a reactive coeffect** — `Session.subscribe/1` fans out
  `{:dsh_session_event, event}` per append (dead subscribers cleaned via
  `:DOWN`), so the chat pane re-renders incrementally as the loop produces tool
  calls and the answer — real-time execution visibility without polling.
- **Todo tool (agent-driven plan)** — `DshBeam.Tool.Todo` ports the reference
  `todo/write` model: a `todo_write` tool appends whole-list snapshots to the
  session (last-write-wins), and the console projects the latest snapshot into
  a plan panel. The agent plans by calling a tool; the plan is a session
  projection, not a separate store.
- The model/credential/settings UX is the existing llm-settings panel plus the
  typed inventory/settings panel (milestones 5/15).
- An end-to-end console test drives a scripted model that writes a todo plan and
  runs a tool in one turn, asserting the chat pane, the todo panel, and the
  session all reflect it. 105 tests.

## 24. Milestone 13 — safety guards + plugin export (complete)

Two safety guards ported from the reference harness's `guard/*` family, plus
creator-defined plugin sources made deployable — all as plugins, not loop
hacks.

- **`DshBeam.Guard.TimeoutPolicy`** — the reference `guard/timeout-policy`. A
  tool declares `timeout_ms` in its DSL; the loop bounds each call to that
  budget (cooperative, `Task.yield`, not a hard kill) and returns a
  `TOOL_TIMEOUT` result when the deadline wins. Zero-config: the budget lives
  on the tool's own declaration (`DshBeam.Tool.Registry.timeout/1`).
- **`DshBeam.Guard.RepeatToolReminder`** — the reference
  `guard/repeat-tool-reminder`. Tracks runs of consecutive identical
  (canonicalized) tool calls and injects an advisory nudge at thresholds
  `[3,5,8]` — advisory only, no veto; the decision stays with the model.
- **Plugin export/import** — `DshBeam.Creator.export_plugin/3` writes the live
  composition + creator-defined source as a deployable `.exs` script
  (recompiled from source, not a binary), and `import_plugin/1` boots a fresh
  runtime from it. The console's creator panel gains an "export plugin (.exs)"
  button. An edited plugin now survives a restart and can be shared — the
  "asset" the user asked for, named in the harness's own domain vocabulary
  ("plugin"), not "asset".
- 114 tests.
