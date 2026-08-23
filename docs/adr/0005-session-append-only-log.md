# 0005. Session as an append-only log (single source of truth)

- **Status**: accepted
- **Date**: 2026-08-22 (reaffirmed 2026-08-23)

## Context

The agent loop and the console chat pane both need conversation history; the
todo list, the tool trace, and the model context all derive from it. The
reference models these as *session events* with *projections* (`todo/write`
last-write-wins, etc.).

## Decision

Make `DshBeam.Session` an **append-only event log** and the single source of
truth. The loop records each turn chronologically (`user` → `tool_call` →
`tool_result` → `assistant`, or `error`); the chat pane, the todo panel, and
the multi-turn model context are all *projections* of that log. `clear/1`
("new conversation") truncates it.

## Alternatives considered

- **Separate stores per concern** (chat history, todo list, tool trace) —
  rejected: they would drift; the paper's unified context argues for one log.
- **LiveView assigns as the chat source** — rejected: lost on refresh; the
  session must survive a page reload.

## Consequences

- A page refresh re-reads the conversation; the todo panel is a projection, not
  a store; the model context replays prior turns.
- The log is append-only, so history is immutable by construction.
- Session was later made *subscribable* (a reactive coeffect) so the pane
  re-renders per append rather than polling (see PLAN milestone 12).
