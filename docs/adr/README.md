# Architecture Decision Records

This directory records the decisions that shaped dsh-beam. Each record answers
*why* a choice was made, what alternatives were considered, and what would have
to change for the decision to be revisited. They are the "history of the
project" a new contributor reads to understand the shape of the code.

## Reading the records

Start here if you are new: `0010-phoenix-liveview-over-react.md` and
`0001-otp-substrate.md` explain the two highest-leverage choices — *what
platform* and *how the UI is built* — and everything else hangs off them.

## Index

| ADR | Title | Status |
|---|---|---|
| [0001](0001-otp-substrate.md) | Elixir/OTP as the substrate | accepted |
| [0002](0002-cordis-substrate-and-plugin-layers.md) | Cordis substrate / harness-plugin layer split | accepted |
| [0003](0003-spark-dsl-for-declarations.md) | Spark DSL for plugin declarations | accepted |
| [0004](0004-fiber-as-gen-statem-process.md) | Promote the fiber to a :gen_statem process | accepted |
| [0005](0005-session-append-only-log.md) | Session as an append-only log (single source of truth) | accepted |
| [0006](0006-credentials-as-references.md) | Credentials as references, never literal keys | accepted |
| [0007](0007-sandbox-as-child-os-process.md) | Sandbox = untrusted code in a child OS process | accepted |
| [0008](0008-intercept-is-provider-wrapping.md) | Access control as provider wrapping (intercept) | accepted |
| [0009](0009-typed-settings-store.md) | Typed settings as a layered store | accepted |
| [0010](0010-phoenix-liveview-over-react.md) | Phoenix LiveView (not React/Hologram/live_react) for the UI | accepted |
| [0011](0011-disable-phoenix-code-reloader.md) | Disable the Phoenix code reloader in dev | accepted |
| [0012](0012-builtin-type-checker-and-credo.md) | Built-in type checker + scoped Credo (no dialyzer) | accepted |
| [0013](0013-ui-slots-for-panels.md) | UI slots: a UI panel is a plugin | accepted |
| [0014](0014-session-surface-and-kv-cache.md) | Session history as an append-only log with a derived model surface (KV-cache reuse) | accepted |
| [0015](0015-llm-adapter-is-a-plugin.md) | LLM adapters are plugins, not behaviour values | accepted |
| [0016](0016-workspace-session-worktree.md) | Session = git worktree: per-session isolation over one repository | accepted |
| [0017](0017-element-select-creator-feedback.md) | ElementSelect: a creator-plugin feedback channel from UI to agent | accepted |

## How to add an ADR

1. Copy `template.md` to `NNNN-<slug>.md` (next number in the index).
2. Fill in the sections; keep each one short — the record is the *decision and
   its context*, not the full design (that lives in PLAN.md and the code).
3. Add a row to the index above.
4. Mark the status `accepted`; use `superseded` + link the replacement when a
   later decision reverses it.

## Statuses

- `accepted` — the decision stands.
- `proposed` — under discussion, not yet binding.
- `superseded` — replaced by a later ADR (link it).
- `deprecated` — no longer applicable, retained for history.

## Conventions

- **English only** — the repository's docs are English-only.
- **One decision per record** — a record that can't be summarized in one
  sentence is two records.
- **Record the tradeoff** — an ADR without "alternatives considered" is a
  changelog entry, not a decision.
- **Consequences are mandatory** — what got easier, what got harder, what must
  be revisited.
