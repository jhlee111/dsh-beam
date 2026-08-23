# Glossary

Vocabulary from the paper, the reference harness, and this port. Ordered roughly
foundation-first.

## The paper (spatiotemporal composability)

- **Revertible effect** — a context transformation `Γ → Γ` paired with an
  inverse `Γ → Γ`; the runtime tracks inverses in a LIFO accumulator so a
  component's contributions can be rolled back on removal. In code: a closure
  returning `{new_state, inverse}`.
- **Reactive coeffect** — a component *declares* dependency keys `d` and is
  *notified* (activate/deactivate/neutral) when they change. The spatial
  dimension.
- **Unified context (Γ)** — the effect context and coeffect context merged into
  one state type.
- **Fiber** — a component *instance*; the unit of lifecycle and rollback.
- **Committed view (ω)** — the resolved `{key → value}` snapshot a fiber was
  activated with; preserved across a provider's teardown so dependents can
  drain (ordered shutdown).
- **L-Unload guard** — a provider withdraws only after every consumer that
  resolved it is deactivated; no deadlock, dependency-order aligned.
- **Recovery exactness** — running a fiber's accumulator removes *only* that
  fiber's contributions.
- **Confluence** — the quiescent state depends only on the final configuration,
  not the order of reconfiguration.

## The reference harness (cordis / dsh)

- **Cordis** — the TS substrate ("everything is a plugin"); our
  `lib/dsh/cordis/*` mirrors it.
- **Inject / intercept** — *inject* gives a capability; *intercept* wraps a
  provider so different consumers see different views (access control).
- **Slot (ui-slots)** — a UI position a plugin registers a component into
  (`kind` × `scope`). Ported as the `ui_slot` DSL.
- **Session projection** — a value *derived* from session events (e.g. the todo
  list = last `todo/write` snapshot), not a separate store.

## This port (dsh-beam)

- **Substrate** — `lib/dsh/cordis/*`; the premise, not a plugin.
- **Entry** — one row of a desired composition: `{id, plugin, config, disabled}`.
- **Runtime** — reconciles entries against running fibers (start/stop/restart +
  crash re-injection).
- **Seam** — a Definition-owned call surface (`DshBeam.Session`, `DshBeam.Llm`,
  `DshBeam.Tool`) that dispatches to a swappable provider.
- **Provider swap** — changing a provider via config without re-registering.
- **Guard** — an advisory safety plugin over the loop (`TimeoutPolicy`,
  `RepeatToolReminder`); advisory, never a veto.
- **Creator** — compile + mount plugin source at runtime; `define`/`redefine`
  (hot swap)/`undefine`/`export_plugin`.
- **Sandbox** — untrusted source in a child OS process (§6.3 boundary).
- **UI slot** — a plugin-declared UI position (`ui_slot` DSL) composed by
  `DshBeam.Ui.render_slot/3`.
- **Design tokens** — the `--dsw-*` CSS custom properties vendored from the
  reference `ui-theme`; the console's color/type vocabulary.
