# 0015. LLM adapters are plugins, not behaviour values

- **Status**: accepted
- **Date**: 2026-08-23
- **Deciders**: project author (aligning with the reference `llm-deepseek`)

## Context

The project's central principle is "everything is a plugin": a tool, a UI
panel, a safety guard, and a capability are all `use DshBeam.Plugin` fibers
that the substrate composes. The LLM adapter was the one exception: it was a
plain `@behaviour DshBeam.Llm.Adapter` implementation chosen by a `:adapter`
module atom in the provider's config, with no fiber, no lifecycle, and no
`need`/`provide`.

The reference harness does it differently: `llm-deepseek` is a plugin
(`name = 'llm-deepseek'`, `inject = ['llm']`) that constructs an adapter object
and registers it with the core `ctx.llm` service
(`ctx.llm.registerAdapter([PROVIDER], adapter)`). The adapter is *owned by a
plugin*, not referenced from configuration.

## Decision

Make the adapter a plugin, mirroring the reference:

1. `DshBeam.Llm.Adapter.Req` uses `use DshBeam.Plugin` and **provides** an
   adapter capability (`:llm_adapter`) alongside `@behaviour DshBeam.Llm.Adapter`.
   Its `complete/3` logic (transport + wire parsing) is unchanged; only its
   packaging changes from "behaviour value" to "plugin that owns the adapter".

2. `DshBeam.Llm.Plugin` (the `:llm` provider) resolves its adapter from the
   context instead of a `:adapter` config atom. It **needs** the adapter
   capability; when exactly one adapter is mounted it uses it directly, and the
   `:adapter` config becomes an optional hint (name) rather than a hardcoded
   module reference.

3. The `DshBeam.Llm.Adapter` behaviour remains the **transport contract** a
   plugin implements — it is now the interface between two plugins, not a
   strategy table inside one.

## Alternatives considered

- **Keep the behaviour, document it as a "strategy layer"** — rejected: it is
  the only exception to "everything is a plugin", and the reference explicitly
  models the adapter as a plugin (`inject :llm` + `registerAdapter`).
- **Inline adapter logic into `Llm.Plugin`** — rejected: that erases the
  provider-swap seam; multiple providers (DeepSeek, Anthropic, …) need separate
  adapter plugins, each with its own settings/credentials.

## Consequences

- The adapter now has a lifecycle and can `need` other capabilities (e.g. a
  token meter, an attachment seam), matching the reference.
- Adapter swapping becomes **plugin swapping** (mount/unmount `Adapter.Req` for
  `Adapter.Anthropic`), consistent with the provider-swap pattern, instead of a
  config atom change.
- `configure/2` no longer carries `:adapter` as a module atom; it may carry the
  adapter capability name. The credential/base_url/model facts still resolve
  per request (unchanged, ADR-0006).
- This is a breaking change to the llm layer: `Llm.Plugin`, the adapter, and the
  llm/console tests that mount an `:adapter` config must be updated together.
- The `:plug` mock boundary (Req.Test.json) is preserved — it is an
  adapter-config fact, not an adapter identity.
