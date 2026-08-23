# Changelog

## Unreleased

### Models settings surface

- The Models settings tab is now a provider card in the reference's shape:
  a provider name + credential-configured dot, a write-only API-key input
  (env-reference or literal), and a collapsed "customized settings" area for
  `base_url` and `model`. Applying reconfigures the running provider and
  persists the values, and the result line no longer double-inspects.

## 0.1.0 — a usable agent harness (2026-08-23)

The first release that is usable like Claude Code / Codex: workspaces, chat,
trajectory, and settings — all as plugins, verified end-to-end from the
console.

### Workspace / session isolation

- `DshBeam.Workspace.open_session/2` checks out a per-session `git worktree`
  (`session/<id>` branch) and starts the session log in it; `close_session/2`
  removes the worktree and stops the log. Two sessions over one repository
  never share a working directory (ADR-0016).
- `DshBeam.Tool.Bash` and `DshBeam.Tool.Fs` run in the current session's `cwd`
  (they `need(:session)` and resolve the worktree from the session header).
- The console gains a **workspace sidebar** (`DshBeam.Ui.Panel.Workspace`):
  list, create, switch, and close sessions. Switching re-points `:session`
  through the substrate's provider-swap path.

### Trajectory

- `DshBeam.Ui.Panel.Trajectory` projects the session log grouped by turn
  (a `user` event opens a turn; tool calls, results, and the answer follow) —
  the reference `ui-trajectory`, as a plugin.

### Settings surface

- Model selection (llm settings), the plugin inventory, and per-plugin typed
  settings (shell limits, loop budget, the workspace default root) are all
  editable from the console, layered over defaults via `DshBeam.Settings`.

### LLM (with the adapter milestone)

- LLM adapters are plugins, not behaviour values: `use DshBeam.Llm.Adapter`
  provides `:llm_adapter`, and swapping an adapter is swapping a plugin
  (ADR-0015). The Req adapter reports disjoint cache usage (ADR-0014).

### Fixes

- The plugin inventory (and therefore the tool registry and UI panels) no
  longer depends on code-load order: it enumerates the application's modules
  plus runtime-loaded (creator) plugins, so a bare console renders its panels
  deterministically.
- `DshBeam.Git` runs `git(1)` unlinked, so a trapping plugin fiber survives a
  subprocess exit.

### Tests

- 140 tests, one per paper guarantee + the milestone's verification criteria.
