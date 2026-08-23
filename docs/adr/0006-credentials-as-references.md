# 0006. Credentials as references, never literal keys

- **Status**: accepted
- **Date**: 2026-08-22
- **Deciders**: project author

## Context

An LLM provider needs an API key, but keys must not sit in configuration (they
would be logged, diffed, and persisted). The reference harness's `CredentialRef`
carries only a *name* (`apiKeyEnv`), resolved per request.

## Decision

Configuration carries a **credential reference** — `{:env, name}` or
`{:literal, value}` — never a bare key. `DshBeam.Credential.resolve/1` produces
the key *per request*, so changing the credential reaches the next request
without re-mounting the provider. Literal keys typed into the console are held
in the fiber's memory and deliberately *not* persisted.

## Alternatives considered

- **Keys in config / settings store** — rejected: the store is meant to be
  persisted (file persistence is planned); keys must not ride along.
- **Keys as a plain string in the provider state** — rejected: same persistence
  and logging risk, and no indirection for reconfiguration.

## Consequences

- Credential changes are reconfiguration, not re-registration.
- The Phoenix request logger masks `credential_value`/`password`/`api_key`
  (`filter_parameters`), and the console form falls back to GET without the
  LiveView socket — both key-leak mitigations recorded after one incident.
- A literal key is lost on server restart by design; the console UI says so.
