# 0016. Session = git worktree: per-session isolation over one repository

- **Status**: accepted
- **Date**: 2026-08-23
- **Deciders**: project author

## Context

v0.1.0's goal is a multi-session harness: several sessions over the same
repository, each with its own chat, trajectory, and working directory. The
reference `agent-team` documents "shared checkout" as an unsolved limitation —
two agents editing one working directory clobber each other's files. The
harness already has a session log (`DshBeam.Session`) and a workspace roster
(`DshBeam.Workspace`); the missing piece is the *isolation* of each session's
filesystem.

## Decision

A session owns its own **`git worktree`**: `DshBeam.Workspace.open_session/2`
resolves the repository root, checks out a fresh `session/<id>` branch into a
sibling `<repo>-worktrees/<branch>` directory, and starts the session log with
`header.cwd` pointing at that checkout. `close_session/2` runs
`git worktree remove` and stops the log. The session's `cwd` is the workspace
root the tools run in: `DshBeam.Tool.Bash` and `DshBeam.Tool.Fs` declare
`need(:session)` and resolve their working directory from the session header.

Switching the current session re-points the `:session` binding by
reconfiguring the session entry (`config: [session: pid]`) and reconciling —
the substrate's own provider-swap path, not a new mechanism.

## Alternatives considered

- **Shared checkout** — rejected: the exact clobbering the reference documents.
- **Per-session directory without git** — rejected: no branch identity, no way
  to see *which* commit a session started from.
- **git init in a fresh directory for non-repositories** — deferred (open
  question): `open_session` refuses a non-repository today rather than guess.
- **A "current session" pointer process** (a stable pid delegating to the
  current session) — rejected: the substrate already expresses re-pointing as
  a provider swap; a delegation process would be a second, parallel mechanism.

## Consequences

- Two sessions over one repository never share a working directory; a write in
  one worktree is invisible to the other (isolation by construction).
- Tools are session-scoped: they `need(:session)`, so withdrawing the session
  deactivates them first (the L-Unload guard) and their filesystem effects are
  contained to the session's checkout.
- Worktrees are §6.1 "outside the boundary": `close_session` removes one
  best-effort, and an unmount leaves worktrees on disk (session work survives a
  restart); merging a session branch back is deferred past v0.1.0.
- Non-git directories are unsupported (`{:error, :not_a_git_repo}`) until the
  git-init-vs-refuse question is decided.
