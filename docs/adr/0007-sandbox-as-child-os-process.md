# 0007. Sandbox = untrusted code in a child OS process

- **Status**: accepted
- **Date**: 2026-08-22
- **Deciders**: project author

## Context

Creator mode lets a user define a plugin from source. Trusted source may run
in-process (creator); untrusted source needs an execution boundary. The paper's
§6.3 explicitly requires a *different runtime* for that boundary.

## Decision

`DshBeam.Sandbox` runs untrusted plugin source in a **child OS process with its
own BEAM** (`priv/sandbox_runner.exs`, a line-JSON protocol). The guardian fiber
owns the port; a crash kills the child and re-injects a fresh one, crossing the
boundary.

## Alternatives considered

- **In-process with restricted atoms** — rejected: the BEAM cannot safely
  isolate untrusted code that compiles arbitrary modules in-process (atom
  exhaustion, module registry pollution).
- **A container/sandbox service (e2b, gVisor)** — rejected: far too heavy for a
  PoC; a child BEAM process captures the isolation point.

## Consequences

- Untrusted `mount/1` cannot create atoms or touch the host's module registry.
- Only inert data crosses the boundary (capabilities/ports/functions dropped;
  `existing_key!` guards atom creation).
- The boundary is process-granularity, not memory-granularity — a hostile child
  can still burn CPU/disk up to the OS's limits; not a security product.
