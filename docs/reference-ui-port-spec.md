# Reference UI porting spec

Porting spec for five reference web-UI surfaces that dsh-beam does not yet have:
**(1) Chat vs Trajectory tabs, (2) the chat-input command menu, (3) the
workspace write/read/full-access selector, (4) the LLM model selector, and
(5) the reasoning-effort selector.** Per surface: how the reference implements
it, its UX expression, every icon used, product copy, and the concrete plan for
porting it into the dsh-beam LiveView console as `ui_slot` plugins.

Source of truth: `reference/deepseek-harness` (`apps/web` + `packages/client/*`
+ `packages/interaction/*` + `packages/core/*`). The reference product copy is
Simplified Chinese; quoted verbatim with an English gloss. All file paths below
are relative to `reference/deepseek-harness` unless prefixed `dsh-beam:`.

---

## 0. Icon system (shared)

All glyphs live in `packages/client/ui-primitives/src/icons/index.tsx`: one
named export per glyph, `Icon<Name><Size>` (e.g. `IconSendOutline16`,
`IconChevronDownOutline14`). Each is an inline `<svg>` with
`fill="currentColor"` taking `{ size?, className? }` (size defaults to the
glyph's drawn size; **the trailing number is a name, not the drawn size** —
e.g. `IconWarningOutline16` is a 14×14 glyph). ~71 exports.

Three glyphs used by these surfaces are **hand-inlined SVGs, not `Icon*`**:
the permission shield glyphs (§3), the Send/Stop buttons, and the trajectory
toolbar clock/wrench/info/compaction glyphs.

dsh-beam today uses emoji/char glyphs (`✦ ❯ ⏎ ▾ ☰ 📁`). The port introduces a
small SVG icon component module in `dsh-beam:lib/dsh_beam_web/icons.ex` (one
`Phoenix.Component` function per glyph) so `~H` templates can render them.

---

## 1. Chat vs Trajectory tabs

### 1.1 How it works

The conversation pane has a **view ring** — a `'conversation.view'` slot
(`kind: 'list'`, `scope: 'session'`) with two entries:

| id | order | package | renders |
| --- | --- | --- | --- |
| `chat` | 0 | `ui-conversation` (`apply.ts`) | keyed append-ordered **chat nodes** (`ChatView`) |
| `trajectory` | 10 | `ui-trajectory` (`index.ts`) | turn-aware **event ledger** (`TrajectoryView`) |

The active view is **per-session store state, not a route**:
`ChatStoreState.view: string | null` (`null` → `chat` fallback). The body
renders `renderSlot('conversation.view', …, { only: active.id })`. Tab labels
are locale-bound thunks (`resolveSlotLabel`). Chat→Trajectory handoff: a tool
row's "Inspect" pill (`IconInspectOutline12`) writes `inspect {callId}` + sets
view to `trajectory`; the trajectory view scrolls to and acknowledges it.

### 1.2 Tab/header UI

`ConversationSessionHeader` (`skeleton/ConversationSession.tsx`):

```
<header class="header">
  <div class="titleRow"><div class="titleCluster">
    <nav class="crumbs" aria-label="会话层级">…crumbSeg/crumbSep/crumb…</nav>
    <div class="headerActions">…</div>
  </div>
  <div class="headerUtilities">…</div></div>
  {tabs.length > 1 && (
    <div class="tabs" role="tablist">
      <button role="tab" aria-selected={active} class="tab [tabActive]"
              onClick={() => setView(id)}>{label}</button> …
    </div>)}
</header>
```

- **Text-only tabs, no icons.** Active = `.tabActive` + `aria-selected` (the
  business-primary underline the console already draws).
- The tab strip renders only when `tabs.length > 1`; unknown/stale ids fall
  back to `chat`. The header is hidden while the session is blank.

Copy: `view.chat` **对话** / Chat; `view.trajectory` **轨迹** / Trajectory;
`session.hierarchy` **会话层级** / Session hierarchy.

### 1.3 Chat view

`ChatView.tsx` → `ChatNodeSeat` per node → `renderSlot('conversation.chat.node',
{routedOwner}, { entryKey: kind, fallback: <JsonBlock …> })`. Renderer registry
(`register-node-renderers.ts`) maps node kind → component:

| kind | renderer | notes |
| --- | --- | --- |
| `user` / `steering` | `UserMessageNodeView` | right bubble; steering vs user from inbox `claimed` |
| `context` | `ContextMessageNodeView` | `ContextInjectionRow` |
| `assistant-step` | `AssistantNodeView` | `AssistantMarkdown`; skips `tool-call` blocks |
| `command` | `CommandNodeView` | `GenericCommandCard` |
| `manual-compaction` | `ManualCompactionNodeView` | `CompactionCommandCard` |
| `compaction` | `CompactionNodeView` | `CompactionItem` |
| `model-retry` | `RetryNodeView` | `ModelRetryItem` |
| `turn-error` / `turn-max-tokens` | `…NodeView` | `MessageItem.tsx` |
| `turn-tail` | `TurnTailNodeView` | per-turn footer + metrics |
| `unknown` | `UnknownNodeView` | JSON fallback |

Tool-call heads render through `ui-tool`'s recursive tool renderer (a separate
keyed slot), not the chat node registry.

**MessageIconActions** (`MessageIconActions.tsx`) — per-message action row:

| action | icon | copy (zh / en) |
| --- | --- | --- |
| copy | `IconCopyOutline16` ↔ `IconCheckOutline16` (1s) | 复制 / Copy; 复制成功 / Copied |
| branch/fork | `IconBranchOutline16` (turn-tail only) | 在新对话中分支 / branch; 仅可从已完成轮次的最后一条消息分支 / unavailable |
| clock | none | `HH:mm`, `{m}月{d}日 HH:mm`, `{y}年{m}月{d}日 HH:mm`; `· 用时 {d}` / `· 首 token {s}秒` / `· {tps} tok/s` |
| feedback | `IconLikeOutline16` / `IconDislikeOutline16` | 好的回答 / 有问题的回答; note 补充说明 |

**Other rows**: reasoning = `IconThinkOutline14` (title "Think" — hardcoded
English); context injection = `IconBrowseOutline16`@14 (`上下文注入` / recall
`跨会话召回`); command = `IconApiOutline14`@14 (`执行中…` / `命令失败` / `已完成`);
compaction = `IconApiOutline14` + `IconChevronRightOutline14`↔`IconChevronDownOutline14`
(`已压缩 {items} 条历史记录（约 {tokens} tokens）`); turn error/max-tokens/retry
rows; **stopped** = `已停止`; running = **"Deep diving…"** (hardcoded English) +
live clock; back-to-bottom = `IconChevronDownOutline14` (`回到底部`).

**StatsLine** (`StatsLine.tsx`, mounted on the composer dock): pipe-separated
groups, no icons: `{turns} 轮 · {steps} 步` · `LLM {d}` · `工具调用 {d}` ·
`首 token 平均 {d}` · `{tps} tok/s` · `缓存命中 {p}%` · `输入 {n} tok · 输出 {n} tok`.

### 1.4 Trajectory view

`TrajectoryView.tsx` = three stacked regions:

1. **Toolbar** (`TrajectoryToolbar.tsx`): duration toggle (inline clock SVG),
   turns/calls collapse (`⊞`/`⊟` text glyphs), search `IconSearchOutline16`@11
   (`搜索轨迹`). Copy: `Duration / Use actual duration / Turns / Calls / …` —
   most toolbar keys ship English even in zh.
2. **Timeline** (`TrajectoryTimeline.tsx`): three lanes **Input / Model / Tools**
   (hardcoded English); drag-range/pan/zoom; no icons.
3. **Table** (`TrajectoryTable.tsx`, `@tanstack/react-virtual`): virtualized
   ledger `turn → group("Message"|"Step N"|"Compaction <seq>") → cells`, with a
   resizable right-hand **details inspector**.

Cell kind tags (`KIND_ICON`):

| kind | label | icon | size |
| --- | --- | --- | --- |
| `system` | SYSTEM | `IconSettingsOutline16` | 13 |
| `user` | USER | `IconUserOutline16` | 13 |
| `context` | CONTEXT | inline circle-i | 14 |
| `compacted` | COMPACTED | inline arrows | 13 |
| `message` | ASSISTANT | `IconSparkle16` | 13 |
| `tool`/`subtool` | TOOL/SUBTOOL | inline wrench | 13 |

Per-turn header columns: **Input / Output / Think / Time** (hardcoded English).
Details-panel chevrons use `IconChevronRightOutline14`@11/12; close is `×`.
Nearly all details-panel copy is hardcoded English (`Summary / Options / Usage /
Timing / Payload / Result / Schema / …`).

### 1.5 Data/state + porting

Both views are **projections of the same session event log** via two snapshot
builders (`ChatSnapshotBuilder` / `TrajectorySnapshotBuilder`), each a set of
`ConversationNodeDefinition`s matching events. To reach parity dsh-beam's flat
log (`user | assistant | tool_call | tool_result | error | todo_write`) must add:
turn/step boundaries + end reasons, reasoning-vs-text blocks, tool↔result
correlation (+ per-call schema), request headers (system prompt/tools/config),
provider/model, token-usage buckets, and timing/retry — none recorded today.

**dsh-beam plan** (builds on the existing `view_tab` assign +
`render_slot(:conversation, assigns, key: @view_tab)` + `DshBeam.Ui.Panel.Chat`
/ `.Trajectory`):

1. Switch tab labels to **对话 / 轨迹**; hide the strip when only one view is
   registered; fall back unknown → `:chat`.
2. `DshBeam.Ui.ChatEntry`: add the `MessageIconActions` row (copy/feedback/clock
   using the new SVG icons) and a reasoning row (new `reasoning` event shape).
3. `DshBeam.Ui.Panel.Trajectory`: promote `trajectory/1` into a shared
   `DshBeam.Ui.TrajectoryProjection` module; add a toolbar (search) + a
   turn-grouped table with the six kind-tag icons; the timeline/details panel is
   deferred (large JS; a `phx-hook` later).

---

## 2. Chat-input command menu

### 2.1 How it works

Two layered surfaces over one `conversation.input.overlay` slot:

1. **Slash candidate menu** — `ui-input-trigger` (`core/menu.ts`, `MenuView.tsx`):
   a combobox triggered by typing `/` (and `@` for file refs). Fuzzy match
   (DP score + substring filter), grouped command/skill/subagent, MAX_HEIGHT 320,
   focus stays in the textarea.
2. **popupSelect shell** — `ui-commands` (`PopupSelectView.tsx`): a focus-holding
   menu for a command's `options(session)`, with local filter and a
   `RiskConfirmation` gate when an option carries `confirmation`.

The input machine (`ui-conversation/src/client/input/machine.ts`) has phases
`plain / adjudicating / claimed / submitting`; a **claim token** is the
`/name ` prefix the `leadingInput` writes into the draft (with a ghost hint),
held while the draft still `startsWith` it. `decorations.ts` paints the
claim/chip backdrop over the transparent textarea. Picks resolve through four
`PickOutcome`s: `claim` / `insert` / `text` / `handled`.

### 2.2 Command catalog

**Host commands** (served by `command.list({sessionId})` as
`CommandDescriptor[]`, cached in `CommandDirectory`): `/permission`, `/plan`,
`/goal`, `/feedback`, `/compact`, `/export`. **Client contributions/
decorations**: `/model` (contribution, `popupSelect`), `/permission`
(decoration). `/skill` is a plain-text source, not a command. There is **no**
`/retry` or `/fork` command (those are chat-node message actions).

Execution: `remote.commands.execute(sessionId, line)` → host
`CommandRuntime.execute` → appends durable `command/run` + `command/done`
session events → rendered as a `CommandNode` via `conversation.chat.commandview`.

### 2.3 Icons & copy

- "＋" trigger button: `IconPlusOutline16` @14 (`input.commands`).
- Selected/check: `IconCheckOutline16`. Permission chevron: `IconChevronDownOutline14`.
- Plan-chip close: `IconCloseFill14` @12. Toast/risk: `IconWarningOutline16`.
- Reference chips: `ReferenceIcon` (file `IconBrowseOutline16`, folder
  `IconFolderClose16`, session custom glyph).
- Send/Stop are **hand-inlined SVGs** (paper-plane / square), not `Icon*`.

### 2.4 Porting plan

dsh-beam has no command system. Port a faithful minimal version:

1. `dsh-beam:lib/dsh/command.ex` — a `DshBeam.Command` registry (name,
   description, `available?/1`, and either a bare runner or a `popupSelect`
   `{options, on_select}`). Seed commands mapping to dsh-beam reality:
   `/permission` (§3), `/model` (§4/§5), `/plan` (no-op), `/goal` (no-op),
   `/clear` (→ `clear_chat`), `/export` (→ `export_plugin`). Handlers append a
   durable `%{"role" => "command_run"|"command_done", "name" => …}` event so the
   chat pane renders a command card.
2. Add a `:composer_overlay` `ui_slot` + a `ComposerTrigger` JS hook that opens
   the menu on `/` and on the "＋" button; render the candidate list from the
   registry (server-side assign, no client state machine — the LiveView owns
   `draft`/`claim` as assigns).
3. Selection inserts the `/name ` claim token into the draft (ghost hint), or
   runs the command directly; `command/run`+`command/done` render as a
   `GenericCommandCard`-style row in `DshBeam.Ui.ChatEntry`.

---

## 3. Workspace access selector (write / read / full access)

### 3.1 Model

A **permission preset** is a named bundle of two knobs:

| knob | values |
| --- | --- |
| `sandbox` (`SandboxMode`) | `read-only` · `workspace-write` · `danger-full-access` |
| `approval` (`ApprovalPolicy`) | `ask` · `never` |

Shipped presets (`packages/bundle/base/cordis.patch.yml`): `read-only`
(read-only + ask), `workspace-write` (workspace-write + ask),
`danger-full-access` (danger-full-access + never). Labels (kebab→Title-Case,
with a hard override): **Read Only** / **Workspace Write** / **Full access** /
derived **Custom** (never a switch target).

Enforcement: picking appends three log-only durable events — `permission/preset`,
`sandbox/mode`, `approval/policy`; the sandbox backend folds the last
`sandbox/mode` (`effectiveSandboxMode`) and confines `bash`/`fs` (read-only
denies writes, workspace-write confines to session cwd + temp, full-access
bypasses); approval folds `approval/policy` (`never` → deterministic reject
before dispatch, `ask` → waterfall to answerers, fails closed).

### 3.2 Composer "Access" seat

`PermissionSelect.tsx` (renders `null` when the `permissions` projection is
absent). Trigger chip (28px, `Menu side="top"`):

```
<button class="trigger" aria-label="访问模式，当前：{name}" disabled={locked||busy}>
  <span class="triggerIcon">{shieldGlyph}</span>       <!-- 14px -->
  <span class="triggerLabel">{label}</span>
  <IconChevronDownOutline14 class="chevron"/>           <!-- rotates 180° open -->
</button>
```

Menu rows = the three presets (filtered of `custom`), `IconCheckOutline16` on
the current, each with the shield glyph. Choosing `danger-full-access` opens
`RiskConfirmation` (checkbox-gated): title 确认启用 Full access？, description
启用 Full access 后，agent 将减少确认步骤…, acknowledge 我已了解风险，并愿意继续,
cancel 取消, enable 启用 Full access. Safe picks call `command('/permission <id>')`.

**Shield glyph SVGs** (16×16, `fill="none"`, tinted `currentColor`; shared
`shieldOutline` path):

```
shieldOutline = "M8.20554 0.899994L14.7901 3.36857V7.01026C14.7901 12 11.0466 14.2103 8.20554 15.3C5.36446 14.2103 1.62012 12 1.62012 7.01026V3.36857L8.20554 0.899994Z"
```

- **read-only** = shield stroke (`strokeWidth 1.31831`, `strokeLinejoin round`)
  + a check path (fill).
- **workspace-write** = 5 fill paths (shield-with-pencil + two text lines).
- **danger-full-access** = shield stroke + a `!` (two fill bars).

### 3.3 Settings row

`PermissionRow.tsx` (registered `settings.general.item`, `order: -20`) sets the
**default preset for future sessions** (not the current one): a 36px pill
selector (`Menu` + `IconChevronDownOutline14`) + the same `RiskConfirmation`.
Copy: title 权限 / Permission; description 选择新会话的默认权限模式 / Choose the
default permission mode for new sessions. Persisted via the `permission`
settings namespace `defaultPreset` (revision-guarded), pinned into new sessions.

### 3.4 Porting plan

dsh-beam has **no permission/approval system** (README's top wish-list item) but
has the sandbox runner and settings store. Port:

1. `dsh-beam:lib/dsh/permission.ex` — `DshBeam.Permission` plugin holding the
   preset table, `apply(session, preset)` (append a `%{"role" => "permission_preset",
   "preset" => id}` event + fold sandbox/approval), `current/1`, `select_for/1`.
   Persist `default_preset` via `DshBeam.Settings` and pin into new sessions.
2. **Guard-rail seam**: make `DshBeam.Tool.Bash`/`Fs` read the folded sandbox
   mode and confine via the existing `DshBeam.Sandbox` runner; add an approval
   gate (`never`→reject, `ask`→prompt) before dispatch. Add the two model-facing
   policy sentences as `prompt_section`s.
3. `DshBeam.Ui.Panel.Access` — the composer chip (three shield SVGs verbatim) +
   dropdown + `RiskConfirmation` modal; a `DshBeam.Ui.Panel.PermissionRow` in
   General settings. `locked` = the composer's busy/no-session state; hidden
   entirely when no permission plugin is mounted.

---

## 4. LLM model selector

### 4.1 How it works

`ui-model-selection/src/client/ModelSelect.tsx` is the composer's model seat
(`conversation.input.model`). A **two-level menu**:

1. **Root pane** — two rows: Model (`模型` + current name) and Effort (`推理等级`
   + current), each `IconChevronRightOutline14`, drilling into its list.
2. **Model list** — provider-grouped (`<section role="group">` + group title +
   `menuitemradio` rows): model name + description + `IconCheckOutline16` when
   selected; `disabled` while `selecting`.
3. Trigger: `<model> · <effort> <IconChevronDownOutline14>` (chevron rotates).

Data: per-session `ModelDirectory` (`directory.ts`/`service.ts`):
`groups[{id,name,models[{id,name,description,reasoning:{defaultEffort,efforts[]}}]}]`,
`current {provider, model, reasoningEffort?}`. The list + effort vocabulary come
from the **Host** (`@deepseek-ai/dsh-api-remotes`), not a client enum. Errors:
in-menu strip with Retry; rejected *selections* → `Toast` `IconWarningOutline16`.

Keyboard: ArrowUp/Down focus, Enter select, Escape backs out of a pane then
closes; `onBlur`/outside-mousedown close.

### 4.2 Copy (zh / en, `ui-model-selection/src/client/locales.ts`)

| key | zh | en |
| --- | --- | --- |
| `trigger.fallback` | 选择模型 | Select model |
| `menu.model` | 模型 | Model |
| `menu.effort` | 推理等级 | Effort |
| `effort.providerDefault` | Default | Default |
| `status.loading` | 正在刷新模型列表… | Refreshing model list… |
| `empty.models` | 没有可用的模型。 | No models available. |
| `empty.efforts` | 当前模型未提供推理等级。 | This model provides no reasoning effort levels. |
| `command.description` | 选择本会话使用的模型 | Select the model for this conversation |

### 4.3 Settings → Models

`ui-settings-models`: `ModelsSection.tsx`, `ModelListEditor.tsx`,
`ProviderEditor.tsx`, `CustomProviderCard.tsx`, `DeepSeekModelsEditor.tsx`,
onboarding/welcome. Icons: `IconPlusOutline16`@14 (add), `IconTrashOutline16`@14
(remove), `IconChevronDownOutline14` (provider card). **No effort control here**
(composer-only).

### 4.4 Porting plan

`DshBeam.Llm.Plugin` today has one `:model` string (no roster). Port:

1. Add a **model roster** to the LLM capability: a `models` list (provider group
   + name + description + `reasoning.efforts`) from a new setting/store, with
   `select_model/2`, `current_model/1`. Seed DeepSeek `deepseek-chat` /
   `deepseek-reasoner`.
2. `DshBeam.Ui.Panel.ModelSelect` — the composer seat: root Model/Effort rows →
   lists, the exact icons above.
3. Upgrade `DshBeam.Ui.Panel.LlmSettings` to list/edit the roster (add/delete,
   set default).

---

## 5. Reasoning-effort selector

### 5.1 How it works

Effort is the **second pane of `ModelSelect`** (§4), shown only when the
selected model declares `reasoning`. Options = `[Default]` (when no
`defaultEffort`) + each `reasoning.efforts` `{id, name, description}`;
`effectiveEffort = current.reasoningEffort ?? reasoning.defaultEffort`; the
trigger label becomes `{model} · {effortLabel}`.

**Effort values are adapter-driven.** The DeepSeek adapter
(`packages/llm/llm-deepseek`, provider `deepseek-official`) advertises
`off | low | high | max` (names "Off/Low/High/Max", default `high`; `off` only
when thinking is disabled). There is **no `medium`** (fixture-only). Labels are
untranslated adapter names; the only client effort label is "Default"
(`effort.providerDefault`, untranslated in both locales). Wire mapping
(`llm-deepseek/src/serialize.ts`): `off → thinking:disabled`; `low/high/max →
reasoning_effort`.

Data flow: `session.selectModel` → `resolveCallConfig` (materializes default
effort) → `selectionFor(agent).current` (+ `agentDefaultModel.saveSelection`) →
`installModelSelection` on the `agent/request` waterfall → `LlmCallConfig`
`reasoningEffort` → wire `reasoning_effort`/`thinking`.

UX: identical to the model list — `menuitemradio` rows (name + description),
`IconCheckOutline16` on the selected level, `IconChevronRightOutline14` on the
root Effort row, `IconChevronDownOutline14` on the trigger; shared keyboard.

### 5.2 Porting plan

1. Add `reasoning_effort` to the LLM capability/config and thread it into the
   adapter request body (`reasoning_effort` for `deepseek-reasoner`; `off` →
   `thinking:disabled`).
2. The effort list reuses `DshBeam.Ui.Panel.ModelSelect`'s effort pane,
   populated from the selected model's `reasoning.efforts` roster.

---

## 6. Consolidated porting order

1. **Icon module** — `dsh-beam:lib/dsh_beam_web/icons.ex` (the ~18 SVG glyphs:
   chevron-down/right-14, check-16, copy-16, branch-16, think-14, browse-16,
   folder-close-16, api-14, like-16, dislike-16, sparkle-16, user-16,
   settings-16, search-16, plus-16, trash-16, warning-16, close-14/16; plus the
   three permission shield SVGs and the hand-inlined send/stop/clock/wrench/info
   glyphs).
2. **Permission capability + Access seat + settings row + guard seam** (§3) —
   smallest end-to-end, and it lands the `Menu` + `RiskConfirmation` primitives
   reused by §4/§5.
3. **Model roster + Model/Effort seat + Settings models** (§4, §5).
4. **Command registry + menu** (§2) — composes the above seats as commands.
5. **Trajectory upgrade + chat node enhancements** (§1).

Each lands as a `ui_slot` plugin (`use DshBeam.Plugin` + `ui_slot(...)`), never
by editing the shell.
