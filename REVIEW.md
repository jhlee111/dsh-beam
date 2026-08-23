# Code review record (milestone 1)

Merged record from two independent reviewers (A: Elixir official documentation standard, B: correctness · concurrency).
The review was performed on top of three verification passes executed without code modification.

## Verification baseline

- mix format --check-formatted → pass
- mix compile --warnings-as-errors → pass (0 warnings)
- mix test → 15 passed

## Reviewer A — Elixir best practice / official documentation anti-patterns

### [High] H1 — GenServer reentrancy/deadlock + active·inactive asymmetry (DshBeam.Context)

- File: lib/dsh/context.ex — reactivate/2 (246–273), do_unload/2 (277–290), deactivate_dependents/2 (297–310)
- Problem: during unload's handle_call handling, a synchronous GenServer.call({:dsh_deactivate, ...}) to the consumer → if the
  consumer calls back into Context, mutual-wait deadlock. In contrast, activation uses send({:dsh_activate, ...}) async + marks :active
  without confirmation. The asymmetry of activate=async·unconfirmed / deactivate=sync·blocking.
- Basis: hexdocs GenServer (reentrancy caution), process-anti-patterns "Non-atomic operations"
- Suggestion: make deactivation 2-phase (message + ack collection), or unify activation/deactivation under the same async protocol.

### [High] H2 — Supervisor does not maintain desired state → convergence failure (DshBeam.Runtime)

- File: lib/dsh/runtime.ex — start_entry/2 (79–98), stop_entry/2 (100–118), handle_info DOWN (56–59)
- Problem: restart: :temporary + records start failure as pid: nil and only Logger.warning → afterwards, even if the same entry is
  requested again, Loader.diff reports it as "same" and does not retry (permanent absence). On crash, the DOWN handler only
  deletes the entry. Reports :ok even when the desired composition and the actual diverge.
- Basis: process-anti-patterns "Unsupervised processes", hexdocs DynamicSupervisor/Supervisor
- Suggestion: report failure loudly (return :error) or guarantee convergence via retry/re-injection.

### [Medium] M1 — @behaviour DshBeam.Session callbacks are dead code + dual path

- File: lib/dsh/session.ex 25–29, memory.ex 15–21, file.ex 16–22
- Problem: the seam (DshBeam.Session.append/all/count) is a GenServer.call message dispatch, while the provider's
  @behaviour implementation append/all/count is never called anywhere (grep 0 hits) → dead code + dual path.
- Basis: code-anti-patterns "Keeping dead code" / "Accidental double calls"
- Suggestion: use the behaviour callbacks as the actual dispatch path (seam calls provider functions), or drop the callbacks and
  declare only a message-protocol contract.

### [Medium] M2 — Fixed-name ETS + :public

- File: lib/dsh/session/memory.ex 25
- Problem: :ets.new(:dsh_session_memory, [:ordered_set, :public]) → badarg collision if two Memory providers exist at once.
  Current tests pass only by luck thanks to topology (async isolation · link cleanup).
- Basis: hexdocs :ets (name uniqueness/ownership/access rights)
- Suggestion: switch to an anonymous table (:protected) and have the owner keep the tid in state.

### [Medium] M3 — unload via catch :exit in terminate (exception as control flow)

- File: lib/dsh/provider.ex 42–50, consumer.ex 63–71, session/plugin.ex 39–50
- Problem: terminate/2 is not called on :kill, and a synchronous GenServer.call during a shutdown cascade is fragile.
  catch :exit, _ -> :ok swallows the reason. The same logic is copy-pasted 3 times.
- Basis: code-anti-patterns "Using exceptions for control flow", hexdocs GenServer (terminate constraints)
- Suggestion: delegate to a monitor safety net (owner death → do_unload) and remove the terminate unload, or extract a shared helper.

### [Medium] M4 — "durable" claim vs no fsync · open/close per append · O(n)

- File: lib/dsh/session/file.ex (moduledoc 2–6, append 40–44, all 47–50, count 53–55)
- Problem: declared durable but no :sync/fsync (OS buffer). open/close on every append, all/count re-stream the whole file.
- Basis: writing-documentation, code-anti-patterns "Comments over use" / "Speculative assumptions"
- Suggestion: state the fsync policy explicitly or make the wording precise ("OS cache until fsync"), introduce a cursor/counter.

### [Medium] M5 — PLAN's promised :gen_statem 4-state fiber not realized

- File: PLAN.md §3/§4 vs lib/dsh/fiber.ex 10–11 (2 states), context.ex (map records)
- Problem: the fiber is not an independent process and the coordination state is concentrated in a single Context GenServer →
  the paper's central tension of "fiber-unit fine-grained accumulator vs process isolation" is not actually demonstrated.
- Basis: code-anti-patterns "Comments over use", hexdocs :gen_statem
- Suggestion: (a) promote fibers to real :gen_statem/supervisor processes, or (b) correct the docs to a "2-state map-record reduced model".

### [Medium] M6 — check-then-act non-atomicity; Context crashes if target dies

- File: lib/dsh/context.ex 300–302
- Problem: if the target dies between the dep.state check and the GenServer.call, the call exits → the whole Context dies (no trap).
- Basis: process-anti-patterns "Non-atomic operations"
- Suggestion: catch the call or replace with monitor-based cleanup, make deactivation async.

### [Low] L1–L5

- L1 context.ex — inconsistent failure representation (:error / {:unknown, %{}} / :unknown) → unify into one.
- L2 context.ex 217–230 — put_monitor O(n) scan → %{pid => ref} inverse index.
- L3 loader.ex 29–43 — keyword-order-sensitive comparison (spurious restart) → normalize with Map.new. Explicit DynamicSupervisor strategy is unnecessary.
- L4 tests — wait_until polling · fixed timeout · reliance on link cleanup → explicit cleanup via start_supervised!/on_exit.
- L5 README default template ("TODO: Add description") + erl_crash.dump leftover.

## Reviewer A overall assessment

The paper's temperament (recovery exactness · committed view · L-Unload guard · monitor safety net) is well pinned by 15 tests.
However, coordination is piled into a single DshBeam.Context and fibers are not made independent processes, so the paper's core
guarantees (interchangeability · fault isolation) are in fact bypassed, and the coordinator reentrancy/non-atomicity along with the
:temporary supervisor's convergence failure are the main points that depart from idiom. In the next milestone, promote fibers to
processes or correct the docs to the reduced model, and resolve H1·H2 first.

## Reviewer B — correctness · concurrency (report pending)

## Reviewer B — correctness · concurrency · resource management

Verification: mix test 15 passed, mix compile --warnings-as-errors pass. 3 live reproductions (source unmodified).

### [High] H1 — A non-contract dependent crashes the whole Context

- The synchronous GenServer.call at context.ex:302 — if even one plugin declares deps but does not implement {:dsh_deactivate, _},
  the call exits -> the whole Context dies. plugin.ex:14 behaviour declares only start_link.
- Repro: /tmp/noncontract_repro2.exs

### [High] H2 — Context reentrancy in the deactivate handler = circular wait

- Inside handle_call(:unload)/handle_info(:DOWN), synchronous blocking on dependents -> if the handler calls Context again,
  mutual wait (crash after 5 seconds). Repro: /tmp/deadlock_repro.exs

### [High] H3 — register overwrites the fiber when provide+register are mixed, losing the previous inverses

- context.ex register replaces the owner fiber wholesale -> the inverses that provide accumulated are lost ->
  bindings linger even after unload (recovery exactness collapse). Repro: /tmp/provide_register_repro.exs

### [Medium] M1~M5

- M1 provide-depend hierarchy mismatch of the reactive coeffect
- M2 teardown global blocking -> weakened fault isolation
- M3 committed view not guaranteed on the crash path (:kill) (provider dies together via link)
- M4 state consistency on start failure
- M5 concurrency of confluence (reconfiguration order independence) not verified

### [Low] L1~L4

- L1 unbounded history growth / L2 timeouts scattered·fixed / L3 DOWN·explicit-unload race idempotence not verified /
  L4 missing handle_info catch-all in Session.Plugin

### Verdict on the four guarantees

1. Recovery exactness — partially holds: holds on the normal path, breaks when provide+register are mixed (H3).
2. L-Unload guard — holds on the normal path, does not hold on the crash path (:kill) (view holds a dead pid).
3. Confluence — weakly holds on the sequential path, concurrency not verified.
4. Fault isolation — partially holds: fiber-unit recovery holds, weakened by the non-contract dependent (H1) and teardown global blocking (M2).

### Correction of A's M2 (B rebuts — B is right)

- A-M2 (fixed-name ETS collision) is a misdiagnosis. memory.ex's :dsh_session_memory is an identifier name without the :named_table
  option, so it is not global registration, and there is no collision even when two tables coexist. Anonymous tables are cleaned on
  both paths: automatic deletion on owner death + :ets.delete in terminate. -> A-M2 rejected.
- No dynamic atom creation (not a defect).

## Merged verdict and fix plan

The core where the two reviews intersect: (1) Context's synchronous call to dependents inside handle_call = the single cause of
deadlock·global crash, (2) :temporary + failure swallowing = convergence failure, (3) the gap between docs (PLAN) and implementation,
(4) the crash path's unguaranteed guard is a documented tension but needs to be made explicit.

Fix order (TDD: regression tests first):

- P1 (correctness, top priority): register merges the existing fiber (remove overwrite) — start from the H3 regression test.
  [complete: regression test red→green, 16 passed, --warnings-as-errors clean]
- P2 (deadlock·global crash): make deactivation async 2-phase (message + ack collection, timeout fallback),
  inject default activate/deactivate/terminate implementations via the use DshBeam.Plugin macro + compile-enforce the behaviour contract —
  resolves A-H1/B-H1/B-H2/A-M3 at once. Moved the 2 repro scripts into tests.
  [complete: implemented with the C' design (see the correction below). use DshBeam.Plugin macro + pending-unload state machine +
  {:dsh_withdraw}/{:dsh_deactivated} protocol. B-H1/B-H2 regression tests red→green, 18 passed,
  --warnings-as-errors clean. The 1.20 type checker caught 2 dead {:stop} branches, simplifying the contract to the single {:ok, state} shape.]
- P3 (convergence): Runtime — return :error on start failure, self-heal by re-injecting the spec on DOWN — A-H2.
  [complete: reconcile returns {:error, errors}, crash re-injection @max_restarts 3 then records :crash_loop, 2 regression tests red→green]
- P4 (docs·implementation alignment): correct PLAN/moduledoc to the "2-state map-record reduced model" and
  state the fiber :gen_statem process promotion as milestone 2 — A-M5.
  [complete: aligned PLAN §3/§4/§10/§11 with the implementation, §12 defines milestone 2 candidates]
- P5 (hygiene): remove the seam dead code (A-M1), unify the API return shape (L1), monitor inverse index (L2), diff normalization (L3),
  history cap, Session.Plugin catch-all, README writing, delete erl_crash.dump.
  [complete: session seam unified into a call surface+protocol, get returns {:ok,v}|:not_found, monitors %{owner=>ref},
  diff normalized via Map.new, history @max_history 200, README written, crash dump deleted]
- To milestone 2: committed view guarantee on the crash path (ordered shutdown), fiber process promotion, confluence concurrency verification.

### P2 design correction — C' (exit-signal shape, keep-alive delivery)

Problem discovered while detailing the approved C (exit signal + DOWN): the exit signal kills the dependent, so
(a) it contradicts the paper's "fibers survive and can be reactivated even after deactivation" and (b) consumer reactivation
becomes impossible on provider swap. Therefore, keep C's shape (Context never makes a blocking call to dependents,
collects completion in handle_info, pid-agnostic), but deliver not via an exit signal but via a
plain message {:dsh_withdraw, keys}, with completion as a {:dsh_deactivated, pid, keys} ack (or :DOWN,
or timeout). The dependent survives, becomes :inactive, and can be reactivated.

- B-H1: dependent without an ack -> force through via timeout (Context survives)
- B-H2: Context re-call during teardown -> Context is free in handle_info, so deadlock is impossible
- Provider terminate waits for {:dsh_unloaded} before returning -> the resource survives during dependent teardown

## Milestone 2 progress record

### 2-① Fiber :gen_statem process promotion (complete)

- use DshBeam.Plugin creates a :gen_statem 4-state (:inactive/:reloading/:active/:unloading) fiber.
- Every transition reports {:dsh_fiber_state, pid, state} to Context — the mirror is for graph computation, the fiber is authoritative.
- Business hooks attach to transitions (ready/activate/withdraw), recommit on view change during activation (a miniature L-Divert).

### 2-② Crash-path committed view — ordered shutdown (complete)

- Start resources (session servers) unlinked, and register "resource release" in the accumulator as the inverse of DshBeam.Context.effect.
  The inverse runs only after the withdrawal protocol (dependent drain), so even if the provider dies with :kill, the resource stays
  alive during the dependents' teardown. The crash path also passes through the same ordered_withdraw.
- Session server shutdown fallback: Session.Plugin.terminate cleans up any survivors after super (against whole-app shutdown).

### 2 things TDD caught

- Async initialization race where the fiber registers only after start_link returns — synchronized registration in init.
- A design error where a test waiting for "absence of binding" could not distinguish before-registration vs after-withdrawal — wait for registration completion first, then trigger the crash.

### Known limitations (as milestone 2 candidates)

- Runtime's crash re-injection (P3) fails with :already_provided for "bindings mid-withdrawal" —
  re-injection needs backoff/retry. (Does not distinguish intentional kill from crash)
  [resolved: re-injection is asynchronous with exponential backoff (10/20/40ms); a start failing
  with :already_provided retries with a bounded exponential backoff (25..800ms) instead of consuming
  the restart budget; the exit reason distinguishes intentional stops — :normal/:shutdown/:killed are
  recorded and left for a later reconcile, which now re-asserts every desired non-running entry
  (the H2 convergence promise made true). Creator.define became transactional so a failed mount is
  never re-asserted. Regression tests: slow-draining dependent re-injection (red before the fix),
  kill-vs-crash distinction.]

### 2-④ Spark DSL front end (complete)

- Added {:spark, "~> 2.6"} (resolved to 2.7.2). DshBeam.Plugin.Dsl: need/provide sections (top_level),
  DshBeam.Composition: entry section (Def 74's id/plugin/config/disabled). Defined via the Spark Builder API,
  compile-time schema validation + Spark.Dsl.Extension.get_entities introspection (the temperament of cordis_inspect).
- use DshBeam.Plugin generates the default mount from the DSL (need list + provide value/via), user mount is
  overridden via defoverridable. The composition module's entries/1 feeds directly into Runtime input.
- 3 tests: need/provide → mount contract compilation, via MFA value computation, composition DSL → Runtime boot·reconfiguration.
- The existing 27 tests pass unchanged on top of the DSL (regression net established).

## Milestone 3 — Creator mode (complete)

- DshBeam.Creator: define(compile->load->mount) / redefine(transactional HMR: compile first, guarded-pass withdrawal,
  :code.purge/delete + load_binary, rollback on failure) / undefine(withdrawal + code unload).
- BEAM :code server = the runtime module registry of paper §6.4 (introduction·eviction are first-class). Node ESM cannot evict.
- Troubleshooting record: Code.compile_string returns the module as an "Elixir."-prefixed atom -> normalize with Module.concat/1.
  Syntax errors raise instead of returning diagnostics -> rescue SyntaxError/TokenMissingError. :code.load_binary
  returns {:module, mod}.
- Known limitations: creator sources are trusted (atom creation + in-process execution). §6.3 execution boundary (sandbox) is future work.
  [resolved: DshBeam.Sandbox runs untrusted source in a child OS process — its own BEAM —
  spawned as a Port (priv/sandbox_runner.exs compiles and executes there; every atom, module, and
  effect stays in the child). The host adapter DshBeam.Sandbox.Plugin forwards the lifecycle over a
  line-JSON protocol: activate/withdraw cross the boundary, child death maps to a crash that the
  runtime re-injects while the monitor safety net withdraws after dependents drained. Boundary rules:
  entry ids are source hashes (no atoms from the source), only host-known nominal keys
  (String.to_existing_atom) may be referenced, only inert JSON-safe data crosses — capabilities never do.
  5 tests: boundary execution, crash+guard+re-injection (fresh OS pid), dependency activation,
  loud failure, atom containment.]

## Milestone 4 — LLM provider plugin + live web console (complete)

- LLM provider: DshBeam.Llm.Plugin provides :llm via an OpenAI-compatible
  POST /chat/completions (deepseek-chat and peers). The HTTP transport is a
  swappable DshBeam.Llm.Adapter: the real one uses Req (a :plug in its config
  replaces the network, so tests run offline), and an Echo adapter powers the
  console's offline chat. DshBeam.Llm.Chat declares :session + :llm and appends
  both turns as revertible effects; it resolves capabilities at call time so a
  withdrawn provider yields {:error, :capabilities_unavailable} instead of a
  stale pid.
- Observer streams: Context.subscribe / Runtime.subscribe fan out state
  changes and entry changes to subscribers (cleaned up on :DOWN).
- The console is a plugin: DshBeam.Console owns the Phoenix endpoint + pubsub
  (started unlinked, stopped synchronously on withdrawal via a wait-out
  handoff for re-injection). Phoenix 1.8 no longer supervises the pubsub, so
  the console starts it; LiveView 1.2 requires lazy_html (pinned to 0.1.11:
  0.1.12 ships no aarch64-apple-darwin precompiled NIF).
- LiveView tests (6): render + seed demo, chat loop, creator define, sandbox
  define (host module never loaded + HTML-escaped id), kill through the
  runtime event stream (no reload), crash-child re-injection (fresh OS pid).
  Deterministic teardown via start_supervised! (on_exit runs after the test
  process died — a linked runtime was being torn down mid-test).

## Milestone 5 — "everything is a plugin" substrate (complete)

- The LLM/chat layer was kept minimal on purpose: the point is the design, not
  another chat framework. The DeepSeek adapter is a thin non-streaming
  transport; credentials are references (DshBeam.Credential) resolved per
  request; configure/2 reconfigures without re-mounting the fiber.
- `setting` declarations (Spark DSL) + DshBeam.Plugin.Inventory express the
  original harness's plugin inventory and per-plugin typed settings.
- DshBeam.Settings (owned by the Runtime) validates overrides against the
  schema; a :credential setting stores a reference, never a key.
- The console's plugins panel lists the inventory (enabled/disabled) and edits
  settings with Save.
- 71 tests, stable.

## Milestone 6 — breadth: the shell capability (complete)

- DshBeam.Shell.Plugin: a non-LLM provider (:shell) with typed settings and
  subprocess execution (timeout + output cap). The Shell settings mirror the
  original harness's inventory verbatim.
- DshBeam.Shell.Consumer: guard across a non-LLM capability.
- Fixed a latent teardown race (context dies between alive? check and the
  unload call on the runtime exit cascade) — the injected terminate/3 now
  swallows that exit.
