defmodule DshBeamWeb.Layouts do
  @moduledoc false
  use Phoenix.Component

  def app(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={csrf_token()} />
        <title>dsh-beam console</title>
        <link rel="stylesheet" href="/assets/dsw-base.css" />
        <link rel="stylesheet" href="/assets/dsw-design-platform.css" />
        <style>
          /* Component layout only — every color/type value comes from the
             DSH design-platform tokens (--dsw-*), not hard-coded here. */
          body {
            font-family: var(--dsw-font-family, ui-monospace, monospace);
            font-size: 13px;
            margin: 0;
            background: var(--dsw-static-neutral-bluish-950, #0f1115);
            color: var(--dsw-static-neutral-bluish-50, #d7dae0);
          }
          /* Three-column app frame (reference ui-layout AppFrame): sidebar |
             center (conversation) | details. Track widths come from the inline
             grid-template-columns on .frame. */
          .frame {
            position: relative;
            display: grid;
            grid-template-rows: 100%;
            height: 100vh;
            overflow: hidden;
            background: var(--dsw-alias-bg-base);
          }
          .frame-sidebar {
            min-width: 0; overflow: hidden;
            background: var(--dsw-specific-sidebar-fill);
            border-right: 1px solid var(--dsw-alias-border-l1);
          }
          .frame-center { min-width: 0; display: flex; flex-direction: column; overflow: hidden; }
          .frame-details { min-width: 0; overflow: hidden; border-left: 1px solid var(--dsw-alias-border-l2); }
          .sidebar-handle {
            position: absolute; top: 0; bottom: 0; width: 8px; margin-left: -4px;
            cursor: col-resize; z-index: 10; touch-action: none;
          }
          .sidebar-handle:hover { background: var(--dsw-alias-interactive-bg-hover); }
          .details-handle {
            position: absolute; top: 0; bottom: 0; width: 8px;
            cursor: col-resize; z-index: 10; touch-action: none;
          }
          .details-handle:hover { background: var(--dsw-alias-interactive-bg-hover); }

          /* Sidebar column shell (reference ui-sidebar SidebarRoot): brand row,
             workspace browsing region, footer settings seat. */
          .sidebar-root {
            display: flex; flex-direction: column; height: 100%;
            padding: 6px 12px; box-sizing: border-box;
            background: var(--dsw-specific-sidebar-fill);
            color: var(--dsw-alias-label-primary);
            font-size: 14px;
          }
          .logo-row {
            flex: none; display: flex; align-items: center; justify-content: flex-end;
            gap: 8px; height: 60px; padding: 8px 0 8px 4px; margin-bottom: 8px;
            box-sizing: border-box; overflow: hidden;
          }
          .brand {
            flex: 1; min-width: 0; display: inline-flex; align-items: center;
            overflow: hidden; padding: 0; border: none; background: transparent;
            color: inherit; font-size: 17px; font-weight: 600;
            letter-spacing: .02em; white-space: nowrap;
          }
          .toggle {
            flex: none; display: inline-flex; align-items: center; justify-content: center;
            width: 28px; height: 28px; border: none; border-radius: 50%; padding: 0;
            background: transparent; cursor: pointer; color: var(--dsw-alias-label-secondary);
          }
          .toggle:hover { background: var(--dsw-alias-interactive-bg-hover); }
          /* Collapsed rail (reference sidebar 56px rail): brand/region/foot unmount,
             only the expand toggle remains centered. */
          .sidebar-root.collapsed { padding: 18px 10px 6px; align-items: center; }
          .sidebar-root.collapsed .logo-row {
            justify-content: center; height: 36px; padding: 0; margin-bottom: 12px;
          }
          .sidebar-root.collapsed .toggle { width: 36px; height: 36px; color: var(--dsw-alias-label-primary); }
          .region {
            flex: 1; min-height: 0; display: flex; flex-direction: column;
            margin-left: -4px; margin-right: -12px; padding-left: 4px; overflow: hidden;
          }
          .foot { flex: none; display: flex; flex-direction: column; }
          .settings-trigger {
            flex: none; display: flex; align-items: center; gap: 6px; width: 100%;
            min-height: 32px; margin: 0 2px 8px; padding: 6px 10px; box-sizing: border-box;
            border: 1px solid var(--dsw-alias-border-l2); border-radius: 10px;
            background: transparent; color: var(--dsw-alias-label-primary); cursor: pointer;
            font-size: 14px; font-weight: 500; text-align: left;
          }
          .settings-trigger:hover { background: var(--dsw-alias-interactive-bg-hover); }

          /* Conversation column root (reference ui-conversation ConversationRoot):
             header (crumbs + tabs) over the scroll body + composer seat. */
          .conv-root {
            display: flex; flex-direction: column; height: 100%; min-width: 0;
            background: var(--dsw-alias-bg-base);
            overflow: hidden;
            --dsh-chat-content-width: 748px;
          }
          .conv-header { position: relative; flex: none; padding: 12px 28px 0 20px; }
          .conv-header::after {
            content: ''; position: absolute; right: 0; bottom: 1px; left: 0; z-index: 0;
            height: 1px; background: var(--dsw-alias-border-l2); pointer-events: none;
          }
          .title-row { display: flex; align-items: center; min-height: 32px; }
          .crumbs {
            display: flex; align-items: center; gap: 4px; min-width: 0;
            overflow: hidden; white-space: nowrap;
          }
          .crumb {
            max-width: 220px; overflow: hidden; padding: 4px 8px; border: none;
            border-radius: 12px; background: transparent; font-size: 14px; line-height: 20px;
            color: var(--dsw-alias-label-tertiary); text-overflow: ellipsis;
            white-space: nowrap; cursor: pointer;
          }
          .crumb-current { font-weight: 500; color: var(--dsw-alias-label-primary); cursor: default; }
          .header-actions { display: flex; align-items: center; gap: 8px; margin-left: auto; }
          .header-action {
            flex: none; border: 1px solid var(--dsw-alias-border-l2); border-radius: 8px;
            background: transparent; color: var(--dsw-alias-label-secondary);
            padding: 3px 10px; font-size: 12px; cursor: pointer;
          }
          .header-action:hover { background: var(--dsw-alias-interactive-bg-hover); color: var(--dsw-alias-label-primary); }
          .tabs {
            position: relative; z-index: 1; display: flex; gap: 36px;
            margin-top: 4px; padding-left: 8px;
          }
          .tab {
            position: relative; padding: 0 0 11px; border: none; background: transparent;
            font-size: 13px; line-height: 16px; font-weight: 500;
            color: var(--dsw-alias-label-tertiary); cursor: pointer;
          }
          .tab::after {
            content: ''; position: absolute; right: 0; bottom: 1px; left: 0; height: 2px;
            border-radius: 2px; background: transparent;
          }
          .tab-active { color: var(--dsw-alias-state-business-primary); }
          .tab-active::after { background: var(--dsw-alias-state-business-primary); }
          .conv-scroll {
            display: flex; flex: 1; flex-direction: column; min-height: 0;
            overflow-y: auto; overflow-x: hidden; scrollbar-gutter: stable;
            align-items: center;
          }
          .chat-view, .conv-scroll > section {
            width: 100%; max-width: var(--dsh-chat-content-width);
            padding: 20px; box-sizing: border-box;
          }
          .composer-seat {
            display: flex; flex: none; flex-direction: column;
            position: sticky; bottom: 0; z-index: 7; margin-top: auto;
            width: 100%; max-width: calc(var(--dsh-chat-content-width) + 32px);
            padding: 8px 20px; box-sizing: border-box;
            background: linear-gradient(180deg, color-mix(in srgb, var(--dsw-alias-bg-base) 0%, transparent) 0px, var(--dsw-alias-bg-base) 36px);
          }
          .composer {
            position: relative; display: flex; flex-direction: column;
            border: 1px solid var(--dsw-alias-border-l2); border-radius: 14px;
            padding: 10px 12px 40px; background: var(--dsw-alias-bg-layer-1, #1a1f27);
          }
          .composer textarea {
            width: 100%; resize: none; border: none; background: transparent;
            min-height: 44px; max-height: 220px; overflow-y: auto;
            font: inherit; font-size: 15px; line-height: 22px;
            color: var(--dsw-alias-label-primary); box-sizing: border-box;
            padding: 0; outline: none; display: block;
          }
          .composer textarea::placeholder { color: var(--dsw-alias-label-caption); }
          .composer-actions {
            position: absolute; right: 10px; bottom: 10px;
            display: flex; gap: 6px;
          }
          .composer-send {
            border-radius: 8px; padding: 6px 14px; font-weight: 500;
            border: 1px solid var(--dsw-alias-border-l2);
            background: var(--dsw-alias-button-elevated-fill, #1c222b);
            color: var(--dsw-alias-label-primary); cursor: pointer;
          }
          .composer-send:hover { background: var(--dsw-alias-button-floating-hover); }
          .composer-status { margin: 4px 0 0; font-size: 12px; }
          /* Composer toolbar: plugin seats (Access, model, commands) live above
             the textarea (the reference InputBar's tool row). */
          .composer-toolbar {
            display: flex; align-items: center; gap: 8px; flex-wrap: wrap;
            padding: 0 2px 8px;
          }
          /* Permission "Access" seat (reference PermissionSelect). */
          .access-seat { position: relative; display: inline-flex; }
          .access-trigger {
            display: inline-flex; align-items: center; gap: 4px; height: 28px;
            max-width: 220px; padding: 0 4px 0 8px; border-radius: 24px;
            background: transparent; color: var(--dsw-alias-label-secondary);
            font-size: 13px; line-height: 20px; font-weight: 500; cursor: pointer;
          }
          .access-trigger:hover:not(:disabled) { background: var(--dsw-alias-interactive-bg-hover); }
          .access-trigger:disabled { color: var(--dsw-alias-label-dimmed); cursor: default; }
          .access-icon { flex: none; display: inline-flex; align-items: center; }
          .access-icon svg { width: 14px; height: 14px; }
          .access-label { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
          .access-chevron { flex: none; color: var(--dsw-alias-label-caption); transition: transform 120ms ease; }
          .access-chevron.open { transform: rotate(180deg); }
          .access-menu {
            position: absolute; bottom: calc(100% + 8px); left: 0; z-index: 30;
            min-width: 200px; padding: 4px; border-radius: 10px;
            border: 1px solid var(--dsw-alias-border-l1, #232a36);
            background: var(--dsw-static-neutral-bluish-850, #161a21);
            box-shadow: var(--dsw-shadow-lv2, 0 4px 12px rgba(0, 0, 0, .4));
          }
          .access-option {
            display: flex; align-items: center; gap: 8px; width: 100%;
            padding: 6px 8px; border: none; border-radius: 6px; background: transparent;
            color: var(--dsw-alias-label-primary); font-size: 13px; text-align: left; cursor: pointer;
          }
          .access-option:hover { background: var(--dsw-alias-interactive-bg-hover); }
          .access-option.selected { color: var(--dsw-alias-state-business-primary); }
          .access-opt-label { flex: 1; min-width: 0; }
          .access-check { flex: none; margin-left: auto; }
          /* Full-access risk confirmation modal. */
          .access-confirm { width: min(440px, 92vw); flex-direction: column; padding: 16px; }
          .access-confirm h2 { margin: 0 0 8px; }
          .access-ack {
            display: flex; align-items: center; gap: 8px; margin: 12px 0;
            font-size: 13px; color: var(--dsw-alias-label-primary);
            background: transparent; border: none; cursor: pointer; padding: 0; text-align: left;
          }
          .ack-box {
            flex: none; display: inline-flex; align-items: center; justify-content: center;
            width: 16px; height: 16px; border-radius: 4px;
            border: 1px solid var(--dsw-alias-border-l3, #2b3442);
            font-size: 12px; color: #fff;
          }
          .ack-box.checked {
            background: var(--dsw-alias-state-business-primary, #4c82ff);
            border-color: transparent;
          }
          .access-confirm-actions { display: flex; justify-content: flex-end; gap: 8px; }
          .access-confirm-enable {
            background: var(--dsw-alias-state-business-primary, #4c82ff);
            border-color: transparent; color: #fff; font-weight: 500;
          }
          .access-confirm-enable:disabled { opacity: .5; cursor: default; }
          /* Model / effort seat (reference ModelSelect). */
          .model-seat { position: relative; display: inline-flex; }
          .model-trigger {
            display: inline-flex; align-items: center; gap: 4px; height: 28px;
            max-width: 240px; padding: 0 4px 0 8px; border-radius: 24px;
            background: transparent; color: var(--dsw-alias-label-secondary);
            font-size: 13px; line-height: 20px; font-weight: 500; cursor: pointer;
          }
          .model-trigger:hover:not(:disabled) { background: var(--dsw-alias-interactive-bg-hover); }
          .model-trigger:disabled { color: var(--dsw-alias-label-dimmed); cursor: default; }
          .model-name { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
          .model-effort { flex: none; color: var(--dsw-alias-label-caption); }
          .model-chevron { flex: none; color: var(--dsw-alias-label-caption); transition: transform 120ms ease; }
          .model-chevron.open { transform: rotate(180deg); }
          .model-menu {
            position: absolute; bottom: calc(100% + 8px); left: 0; z-index: 30;
            min-width: 260px; max-height: 320px; overflow-y: auto; padding: 4px;
            border-radius: 10px; border: 1px solid var(--dsw-alias-border-l1, #232a36);
            background: var(--dsw-static-neutral-bluish-850, #161a21);
            box-shadow: var(--dsw-shadow-lv2, 0 4px 12px rgba(0, 0, 0, .4));
          }
          .model-cell {
            display: flex; align-items: center; gap: 8px; width: 100%;
            padding: 8px; border: none; border-radius: 6px; background: transparent;
            color: var(--dsw-alias-label-primary); font-size: 13px; text-align: left; cursor: pointer;
          }
          .model-cell:hover { background: var(--dsw-alias-interactive-bg-hover); }
          .model-cell-label { font-weight: 500; }
          .model-cell-value { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; color: var(--dsw-alias-label-secondary); }
          .model-cell-chevron { flex: none; color: var(--dsw-alias-label-caption); }
          .model-group-title {
            padding: 8px 8px 2px; font-size: 11px; font-weight: 600; letter-spacing: .03em;
            text-transform: uppercase; color: var(--dsw-alias-label-tertiary);
          }
          .model-option {
            display: flex; align-items: center; gap: 8px; width: 100%;
            padding: 8px; border: none; border-radius: 6px; background: transparent;
            color: var(--dsw-alias-label-primary); font-size: 13px; text-align: left; cursor: pointer;
          }
          .model-option:hover { background: var(--dsw-alias-interactive-bg-hover); }
          .model-option.selected { color: var(--dsw-alias-state-business-primary); }
          .model-option-copy { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 1px; }
          .model-option-name { font-weight: 500; }
          .model-option-desc { font-size: 11px; color: var(--dsw-alias-label-secondary); }
          .model-check { flex: none; margin-left: auto; }
          /* Slash-command menu (reference ui-commands "＋" trigger). */
          .command-seat { position: relative; display: inline-flex; }
          .command-trigger {
            display: inline-flex; align-items: center; justify-content: center;
            width: 28px; height: 28px; border-radius: 8px;
            border: 1px solid var(--dsw-alias-border-l2);
            background: transparent; color: var(--dsw-alias-label-secondary); cursor: pointer;
          }
          .command-trigger:hover:not(:disabled) { background: var(--dsw-alias-interactive-bg-hover); }
          .command-trigger:disabled { color: var(--dsw-alias-label-dimmed); cursor: default; }
          .command-menu {
            position: absolute; bottom: calc(100% + 8px); left: 0; z-index: 30;
            min-width: 240px; max-height: 320px; overflow-y: auto; padding: 4px;
            border-radius: 10px; border: 1px solid var(--dsw-alias-border-l1, #232a36);
            background: var(--dsw-static-neutral-bluish-850, #161a21);
            box-shadow: var(--dsw-shadow-lv2, 0 4px 12px rgba(0, 0, 0, .4));
          }
          .command-option {
            display: flex; align-items: baseline; gap: 8px; width: 100%;
            padding: 6px 8px; border: none; border-radius: 6px; background: transparent;
            color: var(--dsw-alias-label-primary); font-size: 13px; text-align: left; cursor: pointer;
          }
          .command-option:hover { background: var(--dsw-alias-interactive-bg-hover); }
          .command-option-name { flex: none; font-family: var(--ds-font-family-code); font-weight: 600; }
          .command-option-desc { flex: 1; min-width: 0; color: var(--dsw-alias-label-secondary); font-size: 12px; }
          /* Back-to-bottom: a circular chevron floating just above the composer,
             revealed only while the reader is scrolled away from the newest
             message (reference ChatView .toBottom). */
          .to-bottom-wrap {
            position: absolute; right: 20px; bottom: calc(100% + 10px);
            z-index: 8; pointer-events: none;
          }
          .to-bottom {
            display: none; align-items: center; justify-content: center;
            width: 34px; height: 34px; padding: 0;
            border: 1px solid var(--dsw-alias-border-l2); border-radius: 100px;
            color: var(--dsw-alias-label-primary);
            background: var(--dsw-alias-button-floating-fill);
            box-shadow: var(--dsw-shadow-lv2, 0 4px 12px rgba(0, 0, 0, .4));
            cursor: pointer; pointer-events: auto; font-size: 14px;
          }
          .to-bottom.visible { display: flex; }
          .to-bottom:hover { background: var(--dsw-alias-button-floating-hover); }
          .conversation-empty {
            flex: 1; display: flex; flex-direction: column; align-items: center;
            justify-content: center; gap: 6px; padding: 40px 20px; text-align: center;
          }
          .empty-title { font-size: 15px; font-weight: 600; color: var(--dsw-alias-label-primary); }
          .composer-inert { opacity: .55; }

          /* Conversation entries (reference ui-conversation chat + ui-tool). */
          .chat-flow { display: flex; flex-direction: column; gap: 10px; }
          .msg-user { display: flex; justify-content: flex-end; }
          .bubble {
            max-width: min(525px, 82%);
            background: var(--dsw-specific-bubble);
            border-radius: 22px; padding: 10px 16px;
            font-size: 16px; line-height: 24px; color: var(--dsw-alias-label-primary);
            white-space: pre-wrap; overflow-wrap: anywhere;
          }
          .msg-assistant {
            color: var(--dsw-alias-label-primary); font-size: 15px; line-height: 24px;
            display: flex; gap: 8px; align-items: flex-start;
          }
          .role-icon {
            flex: none; display: inline-flex; align-items: center; justify-content: center;
            width: 20px; height: 24px; font-size: 13px; line-height: 1;
          }
          .role-assistant { color: var(--dsw-static-deepseek-400, #679efe); }
          .copy-action {
            flex: none; display: inline-flex; align-items: center; justify-content: center;
            width: 24px; height: 24px; margin-top: 1px; border: none; border-radius: 6px;
            background: transparent; color: var(--dsw-alias-label-secondary); cursor: pointer;
            opacity: 0; transition: opacity 120ms ease;
          }
          .msg-assistant:hover .copy-action { opacity: 1; }
          .copy-action:hover { background: var(--dsw-alias-interactive-bg-hover); color: var(--dsw-alias-label-primary); }
          .copy-action.copied { color: var(--dsw-static-green-500, #34d399); }
          .reasoning-row {
            align-self: flex-start; border: 1px solid var(--dsw-alias-border-l2);
            border-radius: 10px; padding: 6px 10px; font-size: 13px;
            color: var(--dsw-alias-label-secondary); max-width: 100%;
          }
          .reasoning-row summary {
            display: inline-flex; align-items: center; gap: 6px; max-width: 100%;
            cursor: pointer; font-weight: 500; list-style: none; user-select: none;
          }
          .reasoning-row summary::-webkit-details-marker { display: none; }
          .reasoning-icon { flex: none; color: var(--dsw-static-deepseek-400, #679efe); }
          .reasoning-title { flex: none; }
          /* Shared one-line collapse chrome (reference DisclosureRow): a
             separator dot + an ellipsized single-line summary. */
          .row-sep {
            flex: none; width: 3px; height: 3px; border-radius: 50%;
            background: var(--dsw-alias-label-caption);
          }
          .row-summary {
            flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis;
            white-space: nowrap; color: var(--dsw-alias-label-secondary);
            font-weight: 400;
          }
          .reasoning-body {
            margin-top: 6px; padding-top: 6px; border-top: 1px solid var(--dsw-alias-border-l2);
            white-space: pre-wrap; color: var(--dsw-alias-label-tertiary);
          }
          .role-tool { color: var(--dsw-static-green-500, #34d399); }
          .role-error { color: var(--dsw-static-red-400, #fb7185); }
          .turn-status {
            align-self: flex-start; flex: none; display: inline-flex; align-items: center;
            height: 26px; font-size: 14px; font-weight: 500; white-space: nowrap;
            background: linear-gradient(
              90deg,
              var(--dsw-static-deepseek-500) 0%,
              var(--dsw-static-deepseek-500) 40%,
              var(--dsw-static-deepseek-200) 50%,
              var(--dsw-static-deepseek-500) 60%,
              var(--dsw-static-deepseek-500) 100%
            );
            background-position: 100% 0;
            background-size: 250% 100%;
            background-clip: text; color: transparent;
            -webkit-background-clip: text; -webkit-text-fill-color: transparent;
            animation: dsh-turn-status-shimmer 1.8s linear infinite;
          }
          .turn-status-clock {
            margin-left: 8px; font-size: 13px; font-weight: 400;
            font-variant-numeric: tabular-nums;
            color: var(--dsw-alias-label-caption);
            -webkit-text-fill-color: var(--dsw-alias-label-caption);
          }
          @keyframes dsh-turn-status-shimmer {
            to { background-position: 0 0; }
          }
          .markdown > :first-child { margin-top: 0; }
          .markdown > :last-child { margin-bottom: 0; }
          .markdown h1, .markdown h2, .markdown h3 { font-size: 15px; margin: 12px 0 4px; color: var(--dsw-alias-label-primary); }
          .markdown p { margin: 6px 0; }
          .markdown ul, .markdown ol { margin: 6px 0; padding-left: 20px; }
          .markdown li { margin: 2px 0; }
          .markdown code {
            background: var(--dsw-static-neutral-bluish-900, #0c0f14);
            padding: 1px 5px; border-radius: 4px;
          }
          .markdown pre {
            background: var(--dsw-static-neutral-bluish-900, #0c0f14);
            border: 1px solid var(--dsw-alias-border-l2); border-radius: 8px;
            padding: 10px; overflow: auto; max-height: 320px;
          }
          .markdown pre code { background: transparent; padding: 0; }
          .markdown blockquote {
            margin: 6px 0; padding: 2px 12px;
            border-left: 3px solid var(--dsw-alias-border-l3); color: var(--dsw-alias-label-secondary);
          }
          .tool-card {
            border: 1px solid var(--dsw-alias-border-l2); border-radius: 10px;
            padding: 8px 12px; background: var(--dsw-alias-bg-layer-1, #1a1f27);
          }
          .tool-label {
            display: block; margin-bottom: 4px;
            color: var(--dsw-alias-label-secondary); font-size: 11px; font-weight: 600;
            letter-spacing: .03em; text-transform: uppercase;
          }
          .tool-command { font-family: var(--ds-font-family-code); font-size: 13px; word-break: break-all; }
          .command-card {
            border: 1px solid var(--dsw-alias-border-l2); border-radius: 10px;
            padding: 8px 12px; background: var(--dsw-alias-bg-layer-1, #1a1f27);
            font-family: var(--ds-font-family-code); font-size: 13px;
          }
          .command-card.command-done { color: var(--dsw-alias-label-secondary); }
          .tool-result {
            border: 1px solid var(--dsw-alias-border-l2); border-radius: 10px;
            background: var(--dsw-static-neutral-bluish-900, #0c0f14); overflow: hidden;
          }
          .tool-result-summary {
            display: flex; align-items: center; gap: 8px; padding: 8px 12px;
            cursor: pointer; list-style: none; user-select: none;
          }
          .tool-result-summary::-webkit-details-marker { display: none; }
          .tool-result-summary .tool-label { flex: none; margin: 0; }
          .tool-result pre {
            margin: 0; padding: 8px 12px; overflow: auto; max-height: 320px;
            border-top: 1px solid var(--dsw-alias-border-l2);
            font-family: var(--ds-font-family-code); font-size: 12px;
            color: var(--dsw-alias-label-primary); white-space: pre-wrap; word-break: break-all;
          }
          .msg-error, .msg-event, .msg-busy { color: var(--dsw-static-red-400); font-size: 13px; }
          .msg-busy { color: var(--dsw-alias-label-secondary); }
          .trajectory-turn { border-top: 1px solid var(--dsw-alias-border-l2); padding: 8px 0; }
          .trajectory-toolbar {
            display: flex; align-items: center; gap: 6px; margin-bottom: 8px;
            border: 1px solid var(--dsw-alias-border-l2); border-radius: 6px; padding: 4px 8px;
            background: var(--dsw-static-neutral-bluish-900, #0c0f14);
          }
          .trajectory-search-icon { display: inline-flex; color: var(--dsw-alias-label-caption); }
          .trajectory-toolbar input {
            flex: 1; border: none; background: transparent; outline: none;
            color: var(--dsw-alias-label-primary); font-size: 12px; padding: 2px 0;
          }
          .trajectory-cells { display: flex; flex-direction: column; gap: 3px; margin-top: 6px; }
          .trajectory-cell {
            display: flex; align-items: baseline; gap: 8px; padding: 3px 6px;
            border-radius: 6px; font-size: 12px;
          }
          .trajectory-cell:hover { background: var(--dsw-alias-interactive-bg-hover); }
          .trajectory-tag {
            flex: none; display: inline-flex; align-items: center; gap: 5px; min-width: 92px;
            color: var(--dsw-alias-label-secondary); font-size: 10px; font-weight: 600;
            letter-spacing: .04em; text-transform: uppercase;
          }
          .tag-glyph { font-size: 12px; }
          .trajectory-text {
            flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis;
            white-space: nowrap; color: var(--dsw-alias-label-primary);
            font-family: var(--ds-font-family-code); font-size: 12px;
          }
          .kind-user .trajectory-tag { color: var(--dsw-static-blue-400, #60a5fa); }
          .kind-message .trajectory-tag { color: var(--dsw-static-deepseek-400, #679efe); }
          .kind-reasoning .trajectory-tag { color: var(--dsw-static-purple-400, #a78bfa); }
          .kind-tool .trajectory-tag { color: var(--dsw-static-amber-400, #f0b429); }
          .kind-command .trajectory-tag { color: var(--dsw-static-green-500, #34d399); }
          .kind-error .trajectory-tag { color: var(--dsw-static-red-400, #fb7185); }
          .kind-system .trajectory-tag { color: var(--dsw-static-neutral-bluish-500, #6b7a90); }
          .kind-request .trajectory-tag { color: var(--dsw-static-cyan-400, #22d3ee); }
          .kind-turn_end .trajectory-tag { color: var(--dsw-static-green-500, #34d399); }

          /* Workspace sidebar: an explicit create form + session list. */
          .workspace-form { display: flex; flex-direction: column; gap: 4px; margin-bottom: 8px; }
          .workspace-form label { color: var(--dsw-alias-label-secondary); font-size: 12px; }
          .workspace-form input { width: 100%; box-sizing: border-box; }
          .new-session-btn {
            margin-top: 6px; border: 1px solid var(--dsw-alias-border-l2);
            background: var(--dsw-alias-button-elevated-fill, #1c222b); color: var(--dsw-alias-label-primary);
            border-radius: 10px; padding: 7px 12px; font-weight: 500; cursor: pointer;
          }
          .new-session-btn:hover { background: var(--dsw-alias-button-floating-hover); }
          .workspace-feedback { font-size: 12px; margin: 4px 0; }
          .empty-hint { font-size: 12px; line-height: 18px; }
          .workspace-list { display: flex; flex-direction: column; gap: 6px; }
          .workspace-row {
            display: flex; align-items: flex-start; gap: 8px;
            border: 1px solid var(--dsw-alias-border-l2); border-radius: 8px; padding: 6px 8px;
          }
          .ws-dot {
            flex: none; width: 8px; height: 8px; margin-top: 5px; border-radius: 50%;
            background: var(--dsw-alias-label-caption);
          }
          .ws-dot.current { background: var(--dsw-static-green-500, #34d399); }
          .workspace-meta { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 1px; }
          .ws-title { font-size: 13px; font-weight: 600; color: var(--dsw-alias-label-primary); }
          .ws-cwd {
            font-size: 11px; color: var(--dsw-alias-label-secondary);
            word-break: break-all; line-height: 15px;
          }
          .workspace-actions { display: flex; flex-direction: column; gap: 4px; }

          /* Workspace folder picker. */
          .repo-picker {
            display: flex; align-items: center; gap: 6px;
            border: 1px solid var(--dsw-alias-border-l3, #2b3442); border-radius: 6px;
            padding: 4px 8px; background: var(--dsw-static-neutral-bluish-900, #0c0f14);
          }
          .repo-path { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-size: 12px; }
          .picker-panel {
            width: min(480px, 92vw); height: min(520px, 84vh);
            flex-direction: column; padding: 12px;
          }
          .picker-head { display: flex; align-items: center; justify-content: space-between; margin-bottom: 8px; }
          .picker-title { font-weight: 600; font-size: 14px; }
          .picker-path {
            border: 1px solid var(--dsw-alias-border-l3, #2b3442); border-radius: 6px;
            padding: 6px 8px; margin-bottom: 8px; background: var(--dsw-static-neutral-bluish-900, #0c0f14);
            font-size: 12px; overflow-x: auto; white-space: nowrap;
          }
          .picker-list { flex: 1; min-height: 0; overflow-y: auto; display: flex; flex-direction: column; gap: 2px; }
          .picker-entry {
            display: flex; align-items: center; gap: 6px; width: 100%;
            border: none; background: transparent; color: var(--dsw-alias-label-primary);
            padding: 6px 8px; border-radius: 6px; text-align: left; cursor: pointer; font-size: 13px;
          }
          .picker-entry:hover { background: var(--dsw-alias-interactive-bg-hover); }
          .picker-foot { margin-top: 10px; }

          /* Settings modal overlay. */
          .settings-overlay {
            position: fixed; inset: 0; z-index: 100;
            display: flex; align-items: center; justify-content: center;
          }
          .settings-backdrop {
            position: absolute; inset: 0;
            background: rgba(0, 0, 0, .6);
          }
          .settings-panel {
            position: relative; z-index: 1;
            display: flex; width: min(760px, 92vw); max-height: 84vh;
            background: var(--dsw-static-neutral-bluish-850, #161a21);
            border: 1px solid var(--dsw-alias-border-l1, #232a36);
            border-radius: 8px; overflow: hidden;
          }
          nav.settings-nav { width: 170px; border-right: 1px solid var(--dsw-alias-border-l1, #232a36); padding: 10px; }
          .settings-nav-item {
            display: block; width: 100%; text-align: left; margin: 2px 0;
            background: transparent; border-color: transparent;
          }
          .settings-nav-item.active { border-color: var(--dsw-static-blue-500, #4b5b75); background: var(--dsw-static-neutral-bluish-900, #0c0f14); }
          .settings-content { flex: 1; padding: 12px; overflow-y: auto; }

          section {
            background: var(--dsw-static-neutral-bluish-850, #161a21);
            border: 1px solid var(--dsw-alias-border-l1, #232a36);
            border-radius: 6px;
            padding: 10px;
          }
          main.main section { margin-bottom: 12px; }
          h2 {
            font-size: 13px; margin: 0 0 8px; text-transform: uppercase; letter-spacing: .06em;
            color: var(--dsw-static-blue-300, #8fa3bf);
          }
          table { width: 100%; border-collapse: collapse; }
          th, td { text-align: left; padding: 3px 6px; border-bottom: 1px solid var(--dsw-alias-border-l1, #20262f); vertical-align: top; }
          th { color: var(--dsw-static-neutral-bluish-500, #6b7a90); font-weight: normal; }
          code, pre { color: var(--dsw-static-blue-300, #9ecbff); }
          .muted { color: var(--dsw-static-neutral-bluish-500, #6b7a90); }
          .state-inactive { color: var(--dsw-static-amber-400, #f0b429); }
          .state-active { color: var(--dsw-static-green-500, #34d399); }
          .state-reloading { color: var(--dsw-static-blue-400, #60a5fa); }
          .state-unloading { color: var(--dsw-static-red-400, #fb7185); }
          .state-gone { color: var(--dsw-static-neutral-bluish-500, #6b7a90); }
          textarea, input, select, button {
            background: var(--dsw-static-neutral-bluish-900, #0c0f14);
            color: var(--dsw-static-neutral-bluish-50, #d7dae0);
            border: 1px solid var(--dsw-alias-border-l3, #2b3442);
            border-radius: 4px; padding: 5px 8px; font-family: inherit; font-size: 12px;
          }
          textarea { width: 100%; min-height: 130px; resize: vertical; }
          button { cursor: pointer; }
          button:hover { border-color: var(--dsw-static-blue-500, #4b5b75); }
          form.row { display: flex; gap: 6px; align-items: center; }
          ul { margin: 0; padding-left: 16px; }
          li { margin: 2px 0; }
          .pill { display: inline-block; padding: 1px 6px; border-radius: 8px; border: 1px solid var(--dsw-alias-border-l3, #2b3442); }
          /* Tall content scrolls inside its panel instead of stretching the
             whole page past the fold — the composition table, plugin list, and
             trajectory are the offenders. */
          .scroll { max-height: 400px; overflow-y: auto; }
          .events { max-height: 200px; overflow-y: auto; }
          .chat { max-height: 260px; overflow-y: auto; }

          /* Configurable plugin cards (reference ui-settings-plugins). */
          .plugins-scroll { display: flex; flex-direction: column; gap: 8px; }
          .plugin-card {
            border: 1px solid var(--dsw-alias-border-l2);
            border-radius: 8px; overflow: hidden;
            background: var(--dsw-alias-bg-layer-1, #1a1f27);
          }
          .plugin-head {
            display: flex; align-items: center; gap: 8px; width: 100%;
            padding: 8px 10px; background: transparent; border: none; cursor: pointer;
            text-align: left; color: inherit; font-size: 14px;
          }
          .plugin-head:hover { background: var(--dsw-alias-interactive-bg-hover); }
          .plugin-name { font-weight: 600; }
          .plugin-desc {
            flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis;
            white-space: nowrap; color: var(--dsw-alias-label-secondary); font-size: 12px;
          }
          .chevron { margin-left: auto; transition: transform .15s var(--ds-ease-in-out); }
          .chevron.open { transform: rotate(180deg); }
          .plugin-body { padding: 8px 10px; border-top: 1px solid var(--dsw-alias-border-l2); }
          .plugin-body label {
            display: block; margin: 8px 0 2px; color: var(--dsw-alias-label-secondary); font-size: 12px;
          }
          .plugin-body input { width: 100%; box-sizing: border-box; }
          .plugin-actions { display: flex; gap: 8px; margin-top: 10px; }
          .pill.unsaved { color: var(--dsw-static-amber-400); border-color: var(--dsw-static-amber-400); }

          /* Agent presets (reference ui-agent-preset) + General settings form. */
          .preset-list { display: flex; flex-direction: column; gap: 8px; margin-top: 8px; }
          .preset-card {
            border: 1px solid var(--dsw-alias-border-l2); border-radius: 8px;
            padding: 8px 10px; background: var(--dsw-alias-bg-layer-1, #1a1f27);
          }
          .preset-card.preset-default { border-color: var(--dsw-alias-state-business-primary); }
          .preset-head { display: flex; align-items: center; gap: 8px; }
          .preset-name { font-weight: 600; }
          .preset-id { font-size: 11px; }
          .preset-actions { display: flex; gap: 8px; margin-top: 8px; }
          .general-form label { display: block; margin: 8px 0 2px; }
          .general-form input, .general-form select { width: 100%; box-sizing: border-box; }
          .general-form button { margin-top: 10px; }

          /* Models provider card (mirrors the reference models section). */
          .provider-card {
            border: 1px solid var(--dsw-alias-border-l3, #2b3442);
            border-radius: 6px; padding: 8px; margin-bottom: 8px;
          }
          .provider-head {
            display: flex; align-items: center; gap: 8px; margin-bottom: 8px;
          }
          .provider-name { font-weight: 600; }
          .credential-dot {
            display: inline-block; padding: 1px 6px; border-radius: 8px;
            border: 1px solid var(--dsw-alias-border-l3, #2b3442);
            font-size: 11px;
          }
          .credential-dot.configured { color: var(--dsw-static-green-500, #34d399); }
          .credential-dot.missing { color: var(--dsw-static-amber-400, #f0b429); }
          .key-row { display: flex; gap: 6px; align-items: center; }
          .key-row input { flex: 1; }
          details { margin: 6px 0; }
          summary { cursor: pointer; color: var(--dsw-static-blue-300, #8fa3bf); }
          details label { display: block; margin-top: 6px; }
          details input { width: 100%; }
          .provider-actions { display: flex; gap: 8px; align-items: center; margin-top: 8px; }
        </style>
      </head>
      <body data-ds-dark-theme="">
        {@inner_content}
        <script src="/assets/phoenix.js"></script>
        <script src="/assets/phoenix_live_view.js"></script>
        <script>
          // Resizes the sidebar via the boundary handle: pointer-captured drag
          // updates the grid column live, then pushes the settled width back.
          let SidebarResize = {
            mounted() {
              this.frame = this.el.closest('.frame');
              this.dragging = false;
              this.startX = 0;
              this.startWidth = 0;

              this.currentWidth = () => {
                const cols = getComputedStyle(this.frame).gridTemplateColumns.split(' ');
                return parseFloat(cols[0]) || 280;
              };
              this.setWidth = (w) => {
                // Preserve the (now-draggable) details column while resizing
                // the sidebar, so the two handles never fight over the track.
                const cols = getComputedStyle(this.frame).gridTemplateColumns.split(' ');
                const details = cols[2] || '280px';
                this.frame.style.gridTemplateColumns = `${w}px minmax(0, 1fr) ${details}`;
                this.el.style.left = `${w - 4}px`;
              };
              this.onDown = (e) => {
                e.preventDefault();
                this.dragging = true;
                this.startX = e.clientX;
                this.startWidth = this.currentWidth();
                this.el.setPointerCapture(e.pointerId);
                document.body.style.cursor = 'col-resize';
                document.body.style.userSelect = 'none';
              };
              this.onMove = (e) => {
                if (!this.dragging) return;
                const w = Math.min(520, Math.max(200, this.startWidth + (e.clientX - this.startX)));
                this.setWidth(w);
              };
              this.onUp = () => {
                if (!this.dragging) return;
                this.dragging = false;
                document.body.style.cursor = '';
                document.body.style.userSelect = '';
                this.pushEvent('resize_sidebar', { width: Math.round(this.currentWidth()) });
              };

              this.el.addEventListener('pointerdown', this.onDown);
              this.el.addEventListener('pointermove', this.onMove);
              this.el.addEventListener('pointerup', this.onUp);
              this.el.addEventListener('pointercancel', this.onUp);
            },
            destroyed() {
              this.el.removeEventListener('pointerdown', this.onDown);
              this.el.removeEventListener('pointermove', this.onMove);
              this.el.removeEventListener('pointerup', this.onUp);
              this.el.removeEventListener('pointercancel', this.onUp);
            }
          };

          // Resizes the details column via its boundary handle. Dragging left
          // widens it, right narrows it; the settled width is pushed back so
          // it survives a re-render.
          let DetailsResize = {
            mounted() {
              this.frame = this.el.closest('.frame');
              this.dragging = false;
              this.startX = 0;
              this.startWidth = 0;

              this.currentWidth = () => {
                const cols = getComputedStyle(this.frame).gridTemplateColumns.split(' ');
                return parseFloat(cols[2]) || 280;
              };
              this.setWidth = (w) => {
                const cols = getComputedStyle(this.frame).gridTemplateColumns.split(' ');
                const sidebar = cols[0] || '280px';
                this.frame.style.gridTemplateColumns = `${sidebar} minmax(0, 1fr) ${w}px`;
              };
              this.onDown = (e) => {
                e.preventDefault();
                this.dragging = true;
                this.startX = e.clientX;
                this.startWidth = this.currentWidth();
                this.el.setPointerCapture(e.pointerId);
                document.body.style.cursor = 'col-resize';
                document.body.style.userSelect = 'none';
              };
              this.onMove = (e) => {
                if (!this.dragging) return;
                const w = Math.min(560, Math.max(200, this.startWidth - (e.clientX - this.startX)));
                this.setWidth(w);
              };
              this.onUp = () => {
                if (!this.dragging) return;
                this.dragging = false;
                document.body.style.cursor = '';
                document.body.style.userSelect = '';
                this.pushEvent('resize_details', { width: Math.round(this.currentWidth()) });
              };

              this.el.addEventListener('pointerdown', this.onDown);
              this.el.addEventListener('pointermove', this.onMove);
              this.el.addEventListener('pointerup', this.onUp);
              this.el.addEventListener('pointercancel', this.onUp);
            },
            destroyed() {
              this.el.removeEventListener('pointerdown', this.onDown);
              this.el.removeEventListener('pointermove', this.onMove);
              this.el.removeEventListener('pointerup', this.onUp);
              this.el.removeEventListener('pointercancel', this.onUp);
            }
          };

          // Auto-grows the composer textarea to fit its content (capped by CSS
          // max-height, after which it scrolls).
          let AutoGrow = {
            mounted() {
              this.grow = () => {
                this.el.style.height = 'auto';
                this.el.style.height = this.el.scrollHeight + 'px';
              };
              this.el.addEventListener('input', this.grow);
              this.grow();
            },
            updated() { this.grow(); },
            destroyed() { this.el.removeEventListener('input', this.grow); }
          };

          // "Deep diving" elapsed-time clock: ticks client-side without a
          // server round-trip, revealing the elapsed time after 15s (the
          // reference's turn status).
          let ElapsedClock = {
            mounted() {
              this.startAt = parseInt(this.el.dataset.startAt, 10) * 1000;
              this.tick = () => {
                const elapsed = Math.max(0, Date.now() - this.startAt);
                const show = elapsed >= 15000;
                this.el.hidden = !show;
                if (show) {
                  const s = Math.floor(elapsed / 1000);
                  const m = Math.floor(s / 60);
                  this.el.textContent = m > 0 ? `${m}m ${String(s % 60).padStart(2, "0")}s` : `${s}s`;
                }
              };
              this.tick();
              this.timer = setInterval(this.tick, 1000);
            },
            destroyed() { clearInterval(this.timer); }
          };

          // Follows the chat stream: keeps the reader pinned to the newest
          // message when new nodes arrive, and reveals a circular "to bottom"
          // button while the reader is scrolled away. The button is queried
          // fresh each time (it mounts only after a workspace session becomes
          // active), and the click is delegated on the scroll element.
          let ScrollFollow = {
            mounted() {
              this.atBottom = true;
              this.frame = null;

              this.isAtBottom = () => {
                const el = this.el;
                return el.scrollHeight - el.scrollTop - el.clientHeight <= 24;
              };

              this.sync = () => {
                this.atBottom = this.isAtBottom();
                const btn = this.el.querySelector('.to-bottom');
                if (btn) btn.classList.toggle('visible', !this.atBottom);
              };

              this.toBottom = () => {
                this.el.scrollTop = this.el.scrollHeight;
                this.atBottom = true;
                const btn = this.el.querySelector('.to-bottom');
                if (btn) btn.classList.remove('visible');
              };

              this.onScroll = () => {
                cancelAnimationFrame(this.frame);
                this.frame = requestAnimationFrame(this.sync);
              };

              this.onClick = (event) => {
                if (event.target.closest('.to-bottom')) this.toBottom();
              };

              this.el.addEventListener('scroll', this.onScroll, { passive: true });
              this.el.addEventListener('click', this.onClick);

              // New nodes (streaming tool calls / assistant text) re-pin only
              // while already at the bottom.
              this.observer = new MutationObserver(() => {
                if (this.atBottom) this.el.scrollTop = this.el.scrollHeight;
              });
              this.observer.observe(this.el, { childList: true, subtree: true, characterData: true });

              this.el.scrollTop = this.el.scrollHeight;
              this.sync();
            },
            destroyed() {
              this.observer && this.observer.disconnect();
              this.el.removeEventListener('scroll', this.onScroll);
              this.el.removeEventListener('click', this.onClick);
            }
          };

          let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content");
          let liveSocket = new LiveView.LiveSocket("/live", Phoenix.Socket, {
            params: { _csrf_token: csrfToken },
            hooks: { ElapsedClock, ScrollFollow, AutoGrow, SidebarResize, DetailsResize }
          });
          liveSocket.connect();
          window.addEventListener("phx:page-loading-stop", () => liveSocket.enableDebug());

          // Delegated copy: a .copy-action click writes its data-copy to the
          // clipboard and flips to a checkmark for a second (reference
          // MessageIconActions copy). Delegated so it survives morphdom without
          // a per-message hook id.
          document.addEventListener('click', (event) => {
            const btn = event.target.closest('.copy-action');
            if (!btn) return;
            const text = btn.dataset.copy || '';
            if (navigator.clipboard && navigator.clipboard.writeText) {
              navigator.clipboard.writeText(text);
            }
            btn.classList.add('copied');
            setTimeout(() => btn.classList.remove('copied'), 1000);
          });
        </script>
      </body>
    </html>
    """
  end

  defp csrf_token, do: Plug.CSRFProtection.get_csrf_token()
end
