# 0008. Access control as provider wrapping (intercept)

- **Status**: accepted
- **Date**: 2026-08-23
- **Deciders**: project author

## Context

Cordis distinguishes *injection* (giving a consumer a capability) from
*interception* (wrapping the provider so different consumers see different
views of the same capability). The reference expresses access control this way:
a `need` may declare an `intercept` that wraps the resolved value.

## Decision

A `need` may declare `intercept: {M, :f, args}`; the default mount collects it,
and `resolve`/`reactivate` wrap the committed view **per consumer**. The same
provider resolves to different views for different consumers; a swap re-applies
the intercept; the intercepted consumer is still a dependent (guard holds).

## Alternatives considered

- **Capability tokens checked in each consumer** — rejected: that spreads the
  policy across consumers instead of composing it at resolution.
- **A central ACL registry** — rejected as over-engineering; wrapping at the
  resolution seam is enough for the PoC.

## Consequences

- Policy lives at the dependency declaration, not in the consumer body.
- Different consumers of one provider can have read-only vs read-write views.
- Reconfiguration (provider swap) must re-apply the intercept — tested.
