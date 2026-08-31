# Changelog

## Unreleased

### ElementSelect — creator-plugin feedback (Pick seat)

- The composer toolbar now has a **Pick** seat (`DshBeam.Ui.Panel.ElementSelect`,
  order 15): click it, then click any element of the console. The pick collects
  the element's CSS selector, visible text, HTML snippet **and owning-region
  context** (slot, plugin module, source file — from a `data-dsh-region` marker
  `DshBeam.Ui.render_slot/3` now wraps every contribution in) and injects a
  structured `[요소 지적]` marker into the composer draft, so a follow-up edit
  request reaches the agent with its own source pointer.
- All interactive JS ships as `data-phx-runtime-hook` runtime hooks inside the
  plugin's own markup — no edits to the shell's static hooks map.
- The plugin's `prompt_section` teaches the agent how to resolve a marker to
  source and apply edits live with `define_plugin` / `redefine_plugin`.
- A reusable saved-plugin form ships as `plugins/dsh_ui_element_select.exs`.

### Workspace session UX (row switch + ⋮ close)

- The workspace sidebar's session rows are now themselves the switch control:
  clicking a non-current card switches to that session (no separate button).
- Closing a session is a deliberate two-step path behind a vertical meatball
  (⋮), revealed on hover: **⋮ → close session** fires the unchanged
  `workspace_close` event. The menu closes on outside click / Escape / any
  re-render.


### Tools are a first-class capability namespace

- Tool providers are no longer coeffect `bindings`: a plugin's `tool` names are
  registered by the fiber's `init` into a dedicated tool-provider map, so
  overriding `mount/2` can never drop or shadow a tool, and a tool name can
  coexist with a same-named data binding. The agent loop resolves providers via
  the new `DshBeam.Context.tool/2` instead of `Context.get/2`, which stays
  strictly for data. `DshBeam.WorkspaceFolders` now binds its folder list as
  `:extra_folders` (data) while keeping the `workspace_folders` tool name —
  fixing a `FunctionClauseError` where the tool provider was shadowed by the
  folder list.

### Extra workspace folders

- The workspace sidebar now has an **extra folders** seat: add a few related
  folders (not the whole disk) the agent may reach alongside the session
  worktree. Each folder is an explicit absolute path with its own writable
  flag (read-only refuses writes), and the list is persisted as a typed
  setting on the new `DshBeam.WorkspaceFolders` plugin, so it survives a
  restart.
- `DshBeam.Tool.Fs` resolves `read_file`/`write_file` against the session
  root plus every added folder: reads work on any allowed root, writes are
  refused on a read-only extra folder, and anything outside the roots is
  refused exactly as before (no plugin configured means unchanged behaviour).
- `DshBeam.WorkspaceFolders` also exposes a `workspace_folders` tool so the
  agent loop can list the folders it is allowed to touch.

### Chat watchdog

- The chat pane now runs a turn-scoped watchdog: if the agent loop fiber hangs
  (a `gen_statem` call blocked outside the transport's receive budget), the
  turn is killed and the pane settles with a visible timeout instead of
  staying busy forever. The watchdog is turn-scoped, so a result that arrives
  for an already-settled turn is ignored.

### LLM receive timeout as a typed setting

- `receive_timeout` (ms) is now a typed setting on `DshBeam.Llm.Plugin`,
  exposed in the Models surface and persisted to the settings store, so a slow
  reasoning model can be given a longer per-request budget without recompiling.
  The default moves from 120s to 300s — the 120s budget was too tight for
  `deepseek-reasoner` on a large prompt prefix.

### Chat history — cache-friendly tool turns

- `DshBeam.Llm.Chat` now projects the session log through the same
  `Agent.Loop.Projection` the agent loop replays, so a chat consumer sitting
  between tool runs no longer drops `tool_call`/`tool_result` events: the full
  prefix (assistant `tool_calls` with `""` content, then the `tool` messages)
  replays verbatim into the model. One projection for every model request —
  stable prefix, provider prompt-cache hits preserved (ADR-0014).

### Self-modification — hot swap

- Added a `redefine_plugin` tool: the agent loop can hot-swap an already-mounted
  plugin transactionally (compile new source for the same module name; a failed
  start rolls back). The `self_modification` prompt section now documents the
  create → define → redefine → save workflow.

### System prompt as a plugin registry

- Added a `prompt_section` DSL so any plugin contributes its own guidance to
  the assembled system prompt (the reference's `SystemPrompt` registry). The
  agent loop now builds the system prompt from the harness identity + default
  persona + every plugin's sections, instead of a hardcoded one-liner. The
  self-modification tool documents its create → define → save workflow there.

### Self-modification + reusable plugins

- The agent loop can now author plugins from inside a workspace: a
  `define_plugin` tool compiles and mounts a plugin live (in-process, via
  `DshBeam.Creator.define`), and a `save_plugin` tool persists its source as a
  reusable `.exs` under `~/.dsh/plugins`. The console loads those saved plugins
  on boot, so a plugin made in one workspace is available in every project.

### Sidebar

- Session cards use a small current-indicator dot instead of a large pill, a
  friendly title (the workspace folder name, not the internal branch), and a
  wrapping cwd path. The sidebar boundary is now draggable to resize (clamped
  200–520px), with the settled width persisted.

### Conversation composer

- The composer is now a larger card with an auto-growing textarea (44px min,
  220px max, then scrolls) instead of a single-line input, and the send/stop
  control sits inside the card's bottom-right corner.

### Conversation rendering

- Added the reference's back-to-bottom control: a circular chevron floats just
  above the composer while the reader is scrolled away from the newest message,
  and clicking it scrolls to the bottom. A client-side hook also follows the
  stream — while pinned to the bottom, new nodes keep the view scrolled to the
  latest message.

### Fixes

- Closing the current workspace session no longer crashes the console: the
  chat/todo/trajectory projections now guard against a stale (dead) `:session`
  binding instead of calling `subscribe`/`all` on the killed pid. Closing also
  reports "session closed" instead of a raw `:ok`.

### Conversation rendering

- Ported the reference chat's role chrome: assistant/tool/error entries carry
  small colored role icons (✦ brand-blue assistant, ❯/⏎ green tool, ⚠ red
  error), and a running turn renders the "Deep diving…" shimmer with an
  elapsed-time clock (a client-side hook that reveals elapsed after 15s).

### Conversation gated on a workspace session

- The chat/trajectory conversation and its composer only render while a
  workspace session is current. With no workspace open, the conversation
  column shows an empty state ("no workspace open") and an inert composer,
  so the chat no longer silently runs over the boot's default directory.

### Conversation rendering

- Long tool output and markdown code blocks are capped to a scrollable
  `max-height` (320px) instead of expanding the transcript to the full
  content, matching the reference's collapsed-to-max presentation.

### Workspace sessions — relaxed to any folder

- Opening a session no longer requires a git repository. A folder inside a git
  repo still gets a `git worktree` checkout when the checkout succeeds; a
  non-repo folder, or a repo whose worktree cannot be created (permissions),
  opens in-place rooted at the folder itself. `close_session` only removes a
  worktree when one was created.

### Workspace folder picker

- The workspace "repository" field is now a folder picker (a server-side
  directory browser, since the browser File System Access API cannot expose a
  picked folder's path): a "browse" button opens an overlay to navigate
  subdirectories and select a real path. The raw path input and the misleading
  "repository path (a git repo)" copy are gone.
- Removed the stray "new conversation" button from the conversation header;
  opening a new session is the sidebar workspace's "+ new session", which is
  where multiple sessions within a workspace are opened.

### Sidebar toggle

- The sidebar "panel" control is now the collapse/expand toggle (280px ↔ 56px
  rail), not a second settings opener. The brand is a static label, and
  Settings opens from the sidebar foot only.

### Conversation composer

- The composer is now a single send/stop toggle (the reference's shape) instead
  of an "ask" + "new conversation" pair: idle shows `send`, a running turn shows
  `stop` (best-effort — it unblocks the pane and marks the session, while the
  synchronous loop may still finish in the background). "new conversation"
  moved to the conversation header as a utility action.

### Conversation rendering

- Chat and Trajectory now render the reference's conversation shape (borrowed
  as LiveView components, not web components): a right-aligned user bubble,
  assistant markdown (Earmark), and terminal-style tool cards showing the
  `bash` command verbatim instead of the raw arguments map, with the tool
  output in a terminal block. Shared via `DshBeam.Ui.ChatEntry`.

### Fixes

- The Settings modal no longer closes when clicking inside the panel (e.g. the
  Models API-key input): the dim backdrop is now a sibling of the panel with
  its own `close_settings` click, so clicks inside the panel can never bubble
  to it. Clicking the backdrop still closes.

### General + Agent presets settings

- A **General** tab persists app preferences (`default_preset`, workspace
  default root) through the settings store, keyed by `DshBeam.Ui.Panel.General`.
- An **Agent presets** tab (reference `ui-agent-preset`) lists built-in
  compositions (Demo / Agent / Chat) as cards with a default marker and
  built-in/custom badge. A preset can be set default (persisted), applied
  (reconciles the runtime composition to its entries), duplicated into a
  custom preset, and deleted (custom only).

### Plugins settings surface — configurable cards

- The Plugins tab now renders each plugin as an accordion card (reference
  `ui-settings-plugins`): a header with a friendly name, an enabled/disabled
  pill, a description, and an unsaved badge; expanding a configurable card
  discloses its typed fields with staged edit + Save/Discard. Edits stage in
  the LiveView until Save writes them (and re-mounts the plugin); Discard
  drops them without writing.

### Console shell — reference layout

- The console now mirrors the reference three-column `AppFrame` grid
  (sidebar | conversation | details), with the reference `ui-sidebar` and
  `ui-conversation` geometry: a sidebar column (brand, workspace browsing
  region, settings seat), a conversation column (crumbs + Chat/Trajectory tabs
  over a scroll body + composer seat), and a details column. Chat and
  Trajectory are tabbed views (`:conversation` keyed slot); Todo lives in the
  details column. The design theme is scoped via `body[data-ds-dark-theme]`,
  so the console renders on the reference's dark token palette.

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

### Crash audit log + supervised orchestrator

- **`DshBeam.CrashAudit`** — a durable, append-only JSONL record of every
  plugin failure the orchestrator observes (`:crashed`, `:crash_loop`,
  `:start_failed`, `:exited`), written next to the settings store
  (`.dsh/crash-audit.log`, gitignored) and fanned out to live subscribers
  (`{:crash_audit, event}`). A crash is no longer only in the runtime's
  in-memory entry record — it survives a console restart, so "what died and
  why" can be diagnosed afterwards (the `erl_crash.dump` postmortem problem).
  The runtime owns the audit (opt-in via `audit_path:`); the new
  `DshBeam.CrashAudit.Plugin` exposes it to the composition as `:crash_audit`.
- **Supervised orchestrator** — `scripts/console.exs` now starts the runtime
  under a `one_for_one` Supervisor (`DshBeam.Console.Supervisor`), so a crash
  of the runtime itself — the one process nothing else watched — re-spawns
  the whole composition instead of taking the console down. The audit trail
  is started before the runtime and outlives runtime re-injections.
- **`DshBeam.Runtime.audit/1`** — accessor for the owned audit pid (`nil`
  when no `audit_path` was configured; tests/library users stay
  side-effect-free).

### Crash audit events inside the session log

- **`DshBeam.CrashAudit.SessionBridge`** — a fiber that depends on `:session`
  and `:crash_audit` and interleaves every crash event as a
  `%{"role" => "crash_audit", kind, id, reason, timestamp}` row in the
  session log, so a crashed plugin is visible *inside the conversation* — the
  chat/trajectory projections read the same append-only log, so the crash
  shows up as a row in the UI, not only in `.dsh/crash-audit.log`.
- The bridge drains the retained audit window on activation (missed events
  during boot are caught up) and dedupes by `{timestamp, kind, id}`, so a
  restarted/re-activated bridge never appends a crash twice.
- The runtime now injects the audit pid into every entry's mount config
  (`:audit`), so `CrashAudit.Plugin` exposes it without calling back into the
  runtime (which would deadlock mid-reconcile).

### Boot-time worktree GC — made conservative (regression fix)

The original boot GC (this release, earlier) deleted live session worktrees:
it swept any merged `session/*` worktree with `git worktree remove --force`,
keyed `keep:` off `File.cwd!()` (which is the test runner / console, not the
agent's worktree), treated a gitignored-only `.dsh/` as "clean", and ran
unconditionally on mount — so a bare `mix test` in the main repo GC'd another
live session's checkout. Two sessions (2051, 5314) died exactly this way.

The sweep is now conservative — a worktree is removed only when ALL hold:

- branch is `session/*` **and** merged into the default branch;
- not in `opts[:keep]` (default: the caller's cwd);
- checkout **older** than `opts[:grace_seconds]` (default 24h) — a worktree
  created moments ago is a live session by definition (grace period);
- **no live marker** (`<worktree>/.dsh/live` — written by
  `DshBeam.Workspace.open_session/3` at checkout, removed by
  `close_session/2`); a marked worktree is never swept (live marker);
- `git worktree remove` **without `--force`** accepts it — git itself refuses
  a tree with modified/untracked files, so a dirty session survives (no
  force); and `clean_worktree?/1` now checks `status --porcelain --ignored`,
  so a tree whose only local artifacts are the gitignored `.dsh/` is never
  treated as clean (ignored-aware clean check).

- **Boot GC is now opt-in (L4):** `DshBeam.Workspace.mount/2` never prunes on
  its own. Only a mount configured with `boot_prune: true` **and** an explicit
  `repo:` (never a `File.cwd!()` guess) runs the sweep — a bare `mix test` or
  a console from an unrelated cwd cannot delete another session's worktree.
  `scripts/console.exs` opts in explicitly with `repo: File.cwd!()`.
- `DshBeam.Git.prune_merged_worktrees/2` removes a worktree only after every
  fence above, deletes the local branch only after the removal succeeds, and
  still prunes stale worktree metadata best-effort.
