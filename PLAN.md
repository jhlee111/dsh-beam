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
