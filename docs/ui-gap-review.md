# Console UI — reference gap review

How the `lib/dsh_beam_web` console measures against the reference DeepSeek
Harness web UI (`reference/deepseek-harness/apps/web` +
`packages/client/ui-*`). The console is a LiveView re-implementation of the
reference's three-column shell, not a 1:1 port: the reference composes React
components through the slot system, the console composes `ui_slot` function
components through `DshBeam.Ui.render_slot/3`.

## Status legend

- ✅ implemented
- 🟡 partial (a simpler stand-in exists)
- ❌ not ported

## Shell and layout

| Reference surface | Status | Console equivalent / gap |
| --- | --- | --- |
| Three-column `AppFrame` (sidebar \| conversation \| details) | ✅ | `.frame` grid in `console_live.ex` |
| Dark theme (`body[data-ds-dark-theme]`) | ✅ | `layouts.ex` |
| Collapsible sidebar (280px ↔ 56px rail) | ✅ | `toggle_sidebar` |
| Draggable **sidebar** resize | ✅ | `SidebarResize` hook |
| Draggable **details** resize | ✅ | `DetailsResize` hook (added this session) |
| Details-column persistent width | 🟡 | in-memory assign only (resets on reload), same as the sidebar |

## Sidebar

| Reference surface | Status | Notes |
| --- | --- | --- |
| Workspace folder picker (native path) | 🟡 | server-side `File.ls` picker (browser cannot expose a picked folder's path) |
| Session list with current indicator | ✅ | `DshBeam.Ui.Panel.Workspace` |
| New/switch/close session | ✅ | `workspace_create/switch/close` |
| Subagent activity in the sidebar | ❌ | no subagent capability yet |

## Conversation column

| Reference surface | Status | Notes |
| --- | --- | --- |
| Chat / Trajectory tabs | ✅ | `view_tab` |
| User bubble, assistant markdown | ✅ | `DshBeam.Ui.ChatEntry` |
| Terminal-style tool cards (bash verbatim) | ✅ | tool_call / tool_result cards |
| Reasoning rows (`deepseek-reasoner`) | ❌ | the wire `reasoning_content` is not surfaced |
| Compaction cards | ❌ | no compaction capability |
| Command cards (web search, etc.) | ❌ | no web-search/subagent tools |
| Turn-tail actions (retry / fork) | ❌ | session is append-only; no retry/fork surgery |
| Turn metrics (ttft, tokens/s, run ms) | ❌ | usage is parsed but not rendered |
| Back-to-bottom + stream follow | ✅ | `ScrollFollow` hook |
| Auto-growing composer | ✅ | `AutoGrow` hook |
| Send / Stop toggle | ✅ | `composer-send` ↔ `stop_chat` |
| **True stop** (cooperative cancellation) | ✅ | `DshBeam.Agent.Cancel` + loop/LLM threading (added this session) |
| Composer command menu (`/`) | ❌ | no command system |
| Composer permission select | ❌ | no approval/permission plugin |
| Composer context meter | ❌ | no context-window budget display |
| Composer model selector | ❌ | model lives in Settings → Models |
| Composer attachments / images | ❌ | no attachment capability |
| Queue (steer queued messages into a running turn) | ❌ | no queue |

## Details column

| Reference surface | Status | Notes |
| --- | --- | --- |
| Todo / plan panel | ✅ | `DshBeam.Ui.Panel.Todo` |
| Goal bar | ❌ | no goal capability |
| Session lifecycle handles | ❌ | no session durability/export surface |

## Settings modal

| Reference surface | Status | Notes |
| --- | --- | --- |
| Models (provider card, API-key form) | ✅ | `LlmSettings`; route fixed to deepseek |
| Model picker + delete | ❌ | single model field, no roster/delete |
| Plugins (accordion, configurable) | ✅ | `Plugins` panel |
| Agent presets (set-default/apply/duplicate/delete) | ✅ | `Presets` panel |
| General (default preset + workspace root) | ✅ | `General` panel |
| Composition / Bindings / Events | ✅ | `Composition` / `Bindings` / `EventFeed` |
| Creator (define + export) | 🟡 | `define` + `export_plugin`; `redefine_plugin` is a tool but has no UI |

## Markdown (assistant output)

| Reference surface | Status | Notes |
| --- | --- | --- |
| GitHub-flavored markdown | ✅ | Earmark |
| Fenced code syntax highlighting | ❌ | code blocks are unstyled plain `<pre>` |
| Math rendering | ❌ | no KaTeX/MathJax |
| Inline code links / file references | ❌ | no reference decoration |

## Session / data plane (durability, not UI chrome)

These are the root cause of several ❌ above: without durable sessions,
retry/fork, subagents, and compaction have no substrate to build on.

- ❌ Session persistence (in-memory ETS only) — README roadmap.
- ❌ Custom agent-preset persistence (only `default_preset` survives restart).

## This session's changes

1. **True loop stop** — `lib/dsh/agent/cancel.ex` (`:atomics`-backed token),
   token threading through `lib/dsh/agent/loop.ex` (step-boundary checks,
   aborted-tool synthesis, `stopped by user` terminal event) and
   `lib/dsh/llm/adapter/req.ex` (the blocking `Req.post` becomes a cancellable
   worker task), wired into `console_live.ex` (`ask`/`stop_chat`).
2. **Details-column resize** — `DetailsResize` hook + `resize_details` event +
   `details_width` assign; the `SidebarResize` hook now preserves the details
   width instead of hard-coding `280px`.

## Highest-value remaining gaps

1. Session durability (JSONL/SQLite) — unblocks retry/fork/subagents.
2. Assistant markdown syntax highlighting (fenced code blocks).
3. Reasoning rows (`deepseek-reasoner` `reasoning_content`).
4. Turn-tail actions (retry) over a durable session.
5. Composer model selector + command menu.
