# 0014. Session history as an append-only log with a derived model surface (for KV-cache reuse)

- **Status**: accepted
- **Date**: 2026-08-23
- **Deciders**: project author (informed by the reference harness's session/surface + token-meter design)

## Context

The agent loop's model requests are derived from conversation history. Every
model call re-sends the accumulated transcript, so the way we *store* history
directly determines whether the provider's prompt cache (KV cache) can be
reused. The reference harness makes this explicit: requests are **log-derived**,
and cache reuse is a **corollary of prefix stability** — if a turn only *appends*
to the transcript, the next request's prefix is unchanged and the provider
reports `prompt_cache_hit_tokens > 0` on every request after the first.

## Decision

Keep a two-layer model, mirroring the reference:

1. **The session log is append-only** and remains the single source of truth.
   Every observable fact (chat transcript, todo plan, tool trace, model
   context) is a *projection* of it. Nothing is edited or deleted in place.

2. **A derived "surface"** is the ordered view of model-visible events only —
   `user/message`, `assistant/message`, `tool/result`. The loop's request is a
   fold of this surface, so a request can always be *reconstructed* from the
   log. Surface events join by `append` (normal turns) or `replace`
   (compaction shadowing a range — the one operation that breaks the prefix).

3. **Usage is reported as disjoint counts.** The adapter maps the provider's
   `prompt_cache_hit_tokens` into a separate `cacheReadTokens` and *subtracts*
   it from `inputTokens` (DeepSeek's `prompt_tokens` includes cache hits; the
   harness convention is disjoint, so `inputTokens + cacheReadTokens` is the
   billed prompt).

In dsh-beam today the log is already append-only (ADR-0005); what this decision
adds is the *explicit* framing: the loop's multi-turn replay is the surface
fold, and prefix stability is a property we preserve deliberately, not by
accident.

## Alternatives considered

- **Store the assembled transcript directly** (not events) — rejected: it
  couples the transcript to one renderer and loses the source for replay,
  projections, and the human transcript (a replaced range would erase what the
  user already saw).
- **Edit/rewrite history in place** — rejected: any mid-prefix change
  invalidates the provider cache; append-only is the cache-friendly shape.
- **Ignore cache accounting** — rejected: `prompt_tokens` would be misread as
  uncached input, and there is no observable for prefix stability.

## Consequences

- Multi-turn requests reuse the provider cache for free, because the loop
  replays the prior surface verbatim and appends only the new turn.
- The chat pane, the todo panel, and the model context are all projections of
  one log (already true; this ADR makes the *surface vs transcript* split
  explicit for when compaction arrives).
- Compaction (future work) is the one operation that breaks the prefix: it must
  `replace` a surface range, and the reference places it *between turns* to
  contain the cache invalidation. That will be its own ADR.
- Consequence to implement now: our `DshBeam.Llm.Adapter.Req` does not yet parse
  `prompt_cache_hit_tokens`/`prompt_cache_miss_tokens`, so cache reuse is
  invisible. The adapter should map disjoint usage; a `DshBeam.TokenMeter`
  plugin can then expose it as a session projection (both are plugins, not
  core — see the reference's split: reconstruction is core, cache parsing and
  measurement are adapter/plugin).

## Where each concern lives (reference → ours)

| Concern | Reference | dsh-beam |
|---|---|---|
| log-derived request (surface fold) | core `agent-loop` | core `Agent.Loop` (has it) |
| append-only log + surface | core `session` | `Session` (log; surface split is implicit) |
| cache usage parsing | adapter `llm-deepseek` | **to add**: `Llm.Adapter.Req` |
| token pressure/usage projection | plugin `token-meter` (inject) | **to add**: `DshBeam.TokenMeter` plugin |
| prefix-breaking ops (compaction) | plugin (compaction) | not implemented |
