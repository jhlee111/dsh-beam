defmodule DshBeam.Ui.Panel.Workspace do
  @moduledoc """
  The workspace sidebar: lists the workspace's sessions (each a git worktree),
  creates new ones, switches the current session, and closes them. A session is
  the unit of the chat/todo/trajectory panes — switching rebinds `:session` to
  the selected worktree.

  ## Switching and closing UX

  A session row is itself the switch control: clicking anywhere on the card
  (non-current rows) switches to that session — no separate button. The only
  per-row control is a vertical meatball (⋮), revealed on hover. Closing is a
  deliberate two-step path so it can't be triggered by accident: **⋮ → close
  session**. The menu is a self-contained Phoenix runtime hook
  (`data-phx-runtime-hook="WorkspaceMenu"`), so the shell's static hooks map
  never changes; the server-side `workspace_close` event is unchanged.
  """

  use DshBeam.Plugin
  import Phoenix.Component

  ui_slot(:sidebar, kind: :list, order: 10, component: {__MODULE__, :panel, []})

  def panel(assigns) do
    ~H"""
    <section>
      <div class="ws-header">
        <h2>workspaces</h2>
        <button
          type="button"
          class="ws-add"
          id="ws-add"
          phx-hook="WsAdd"
          phx-click="browse_dir"
          aria-label="add a workspace folder"
          title="add a workspace folder"
        >+</button>
      </div>

      <%= if @workspace_result do %>
        <p class="workspace-feedback muted"><%= result_label(@workspace_result) %></p>
      <% end %>

      <%= if @workspace_groups == [] do %>
        <p class="muted empty-hint">
          no workspaces yet — press + to add a folder
        </p>
      <% end %>

      <%= for {g, gidx} <- Enum.with_index(@workspace_groups) do %>
        <div class="ws-group">
          <div class="ws-group-head">
            <span class="ws-group-icon" aria-hidden="true">📁</span>
            <span class="ws-group-name" title={g.repo}><%= g.name %></span>
            <span class="ws-group-repo" title={g.repo}><%= g.repo %></span>
            <button
              type="button"
              id={"ws-group-new-" <> Integer.to_string(gidx)}
              class="ws-group-new-btn"
              phx-hook="WsGroupNew"
              data-repo={g.repo}
              title={"new session in " <> g.repo}
            >+ new session</button>
          </div>

          <div class="workspace-list">
            <%= if g.sessions == [] do %>
              <p class="muted empty-hint">no sessions yet — + new session</p>
            <% end %>
            <%= for {s, idx} <- Enum.with_index(g.sessions) do %>
              <div class={"workspace-row #{if s.current, do: "current"}"}>
                <div
                  class="ws-select"
                  phx-click={if s.current, do: nil, else: "workspace_switch"}
                  phx-value-session={s.session_key}
                  role="button"
                  tabindex={if s.current, do: -1, else: 0}
                  aria-label={if s.current, do: "current session", else: "switch to " <> s.title}
                  title={if s.current, do: "current session", else: "switch to this session"}
                >
                  <span class={"ws-dot #{if s.current, do: "current", else: "idle"}"}></span>
                  <div class="workspace-meta">
                    <span class="ws-title"><%= s.title %></span>
                    <span class="ws-cwd" title={s.cwd}><%= s.cwd %></span>
                  </div>
                </div>
                <div class="workspace-actions">
                  <button
                    type="button"
                    class="ws-folders-toggle"
                    aria-label="folders for this session"
                    title="extra folders for this session"
                    phx-click="workspace_folders_toggle"
                    phx-value-session={s.session_key}
                  >folders<%= if s.folders != [], do: " · " <> Integer.to_string(length(s.folders)) %></button>
                  <div
                    id={"ws-menu-" <> Integer.to_string(gidx) <> "-" <> Integer.to_string(idx)}
                    class="ws-menu-wrap"
                    phx-hook="WorkspaceMenu"
                    data-session={s.session_key}
                    data-title={s.title}
                  >
                    <button
                      type="button"
                      class="ws-meatball"
                      aria-label="session actions"
                      aria-haspopup="menu"
                      aria-expanded="false"
                      title="session actions"
                    >⋮</button>
                    <div class="ws-menu" role="menu" hidden>
                      <button
                        type="button"
                        class="ws-menu-item ws-menu-rename"
                        role="menuitem"
                        data-action="rename"
                      >rename session</button>
                      <button
                        type="button"
                        class="ws-menu-item ws-menu-close"
                        role="menuitem"
                        data-action="close"
                      >close session</button>
                    </div>
                  </div>
                </div>
                <%= if @ws_folders_open == s.session_key do %>
                  <div class="ws-session-folders">
                    <p class="muted wf-hint">folders this session may read/write</p>
                    <div class="workspace-list wf-list">
                      <%= if s.folders == [] do %>
                        <p class="muted empty-hint">none yet</p>
                      <% end %>
                      <%= for f <- s.folders do %>
                        <div class="workspace-row wf-row">
                          <span class="ws-dot idle" title={if f.writable, do: "writable", else: "read-only"}></span>
                          <div class="workspace-meta">
                            <span class="ws-cwd" title={f.path}><%= f.path %></span>
                            <span class={"pill #{if f.writable, do: "state-active", else: "state-gone"}"}>
                              <%= if f.writable, do: "writable", else: "read-only" %>
                            </span>
                          </div>
                          <div class="workspace-actions">
                            <button phx-click="workspace_session_folders_remove" phx-value-session={s.session_key} phx-value-path={f.path}>remove</button>
                          </div>
                        </div>
                      <% end %>
                    </div>
                    <form class="workspace-form" phx-submit="workspace_session_folders_add">
                      <input type="hidden" name="session" value={s.session_key} />
                      <label class="muted">folder path</label>
                      <input type="text" name="path" placeholder="/abs/path/to/related/repo" />
                      <label class="wf-check">
                        <input type="checkbox" name="writable" value="true" checked />
                        writable (else read-only)
                      </label>
                      <button type="submit" class="new-session-btn">+ add folder</button>
                    </form>
                  </div>
                <% end %>
              </div>
            <% end %>
          </div>
        </div>
      <% end %>
    </section>

    <style>
      /* The whole card is the switch target (non-current rows); the only
         visible control is a vertical meatball revealed on hover. Closing is
         a two-step path — ⋮ → close session — so it can't be hit by accident. */
      .ws-header { display: flex; align-items: center; gap: 8px; margin-bottom: 6px; }
      .ws-header h2 { margin: 0; }
      .ws-add {
        flex: none; display: inline-flex; align-items: center; justify-content: center;
        width: 22px; height: 22px; border-radius: 6px; padding: 0;
        border: 1px solid var(--dsw-alias-border-l2, #2a3342); background: transparent;
        color: var(--dsw-alias-label-secondary); font-size: 15px; line-height: 1; cursor: pointer;
      }
      .ws-add:hover {
        background: var(--dsw-alias-interactive-bg-hover);
        border-color: var(--dsw-static-deepseek-400, #679efe);
        color: var(--dsw-alias-label-primary);
      }
      .ws-group { margin-bottom: 12px; }
      .ws-group-head {
        display: flex; align-items: center; gap: 6px;
        padding: 4px 2px; border-bottom: 1px solid var(--dsw-alias-border-l2, #2a3342);
        margin-bottom: 4px;
      }
      .ws-group-icon { font-size: 13px; line-height: 1; flex: none; }
      .ws-group-name {
        font-size: 13px; font-weight: 700; color: var(--dsw-alias-label-primary);
        white-space: nowrap; overflow: hidden; text-overflow: ellipsis; min-width: 0;
      }
      .ws-group-repo {
        flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
        font-size: 11px; color: var(--dsw-alias-label-caption);
      }
      .ws-group-new { margin-left: auto; flex: none; }
      .ws-group-new-btn {
        height: 22px; padding: 0 8px; border-radius: 6px;
        border: 1px solid var(--dsw-alias-border-l2, #2a3342);
        background: transparent; color: var(--dsw-alias-label-secondary);
        font-size: 11px; cursor: pointer;
      }
      .ws-group-new-btn:hover {
        background: var(--dsw-alias-interactive-bg-hover);
        border-color: var(--dsw-static-deepseek-400, #679efe);
        color: var(--dsw-alias-label-primary);
      }
      .ws-menu-rename { color: var(--dsw-alias-label-secondary); }
      .workspace-row { transition: background 120ms ease; }
      .workspace-row:not(.current):hover { background: var(--dsw-alias-interactive-bg-hover); }
      .workspace-row:not(.current) .ws-select { cursor: pointer; }
      .workspace-row.current .ws-select { cursor: default; }
      .ws-select {
        flex: 1; min-width: 0; display: flex; align-items: flex-start; gap: 8px;
        padding: 2px; margin: -2px; border-radius: 6px;
      }
      .ws-menu-wrap { position: relative; flex: none; display: inline-flex; }
      .ws-meatball {
        flex: none; display: inline-flex; align-items: center; justify-content: center;
        width: 20px; height: 20px; padding: 0; border-radius: 6px;
        border: 1px solid transparent; background: transparent;
        color: var(--dsw-alias-label-caption); font-size: 13px; line-height: 1;
        cursor: pointer; opacity: 0; transition: opacity 120ms ease;
      }
      .workspace-row:hover .ws-meatball,
      .ws-meatball:focus-visible,
      .ws-menu-wrap.open .ws-meatball { opacity: 1; }
      .ws-meatball:hover {
        color: var(--dsw-alias-label-primary);
        border-color: var(--dsw-alias-border-l2);
      }
      .ws-menu {
        position: absolute; right: 0; top: calc(100% + 4px); z-index: 40;
        min-width: 150px; padding: 4px;
        border-radius: 8px;
        border: 1px solid var(--dsw-alias-border-l1, #232a36);
        background: var(--dsw-static-neutral-bluish-850, #161a21);
        box-shadow: var(--dsw-shadow-lv2, 0 4px 12px rgba(0, 0, 0, .4));
      }
      .ws-menu[hidden] { display: none; }
      .ws-menu-item {
        display: flex; width: 100%; padding: 6px 8px;
        border: none; border-radius: 6px; background: transparent;
        color: var(--dsw-alias-label-primary); font-size: 12px; text-align: left; cursor: pointer;
      }
      .ws-menu-item:hover { background: var(--dsw-alias-interactive-bg-hover); }
      .ws-menu-close { color: var(--dsw-static-red-400, #fb7185); }
      .ws-menu-close:hover { color: var(--dsw-static-red-400, #fb7185); }
      .ws-folders-toggle {
        flex: none; display: inline-flex; align-items: center; gap: 2px;
        height: 20px; padding: 0 6px; border-radius: 6px;
        border: 1px solid var(--dsw-alias-border-l2, #2a3342);
        background: transparent; color: var(--dsw-alias-label-caption);
        font-size: 11px; line-height: 1; cursor: pointer; opacity: 0;
        transition: opacity 120ms ease;
      }
      .workspace-row:hover .ws-folders-toggle,
      .ws-folders-toggle:focus-visible { opacity: 1; }
      .ws-folders-toggle:hover { color: var(--dsw-alias-label-primary); border-color: var(--dsw-alias-border-l1, #232a36); }
      .ws-session-folders {
        grid-column: 1 / -1; margin: 2px 0 4px; padding: 8px;
        border-radius: 8px; border: 1px solid var(--dsw-alias-border-l2, #2a3342);
        background: var(--dsw-static-neutral-bluish-875, #13161c);
      }
      .ws-session-folders .wf-check { margin: 4px 0; }
      .ws-worktree-check { display: flex; align-items: center; gap: 4px; margin: 2px 0; }
      .ws-worktree-check input { width: auto; }
    </style>

    <script data-phx-runtime-hook="WsAdd">
      window.phx_hook_WsAdd = () => ({
        mounted() {
          this.onClick = async (e) => {
            // Native directory picker (Chrome/Edge): folders only, no files.
            // Falls back to the server-side browse_dir picker when unavailable.
            if (window.showDirectoryPicker) {
              e.preventDefault();
              e.stopPropagation();
              try {
                const handle = await window.showDirectoryPicker({ mode: 'read' });
                const path = handle.name ? await this.resolvePath(handle) : '';
                if (path) this.pushEvent('workspace_pick_dir', { path: path });
              } catch (err) {
                if (err && err.name === 'AbortError') return; // user cancelled
                this.pushEvent('browse_dir', {});
              }
            }
          };
          // Resolve a directory handle to a path the server can use. The
          // File System Access API hides the real path, so we walk the handle
          // and, where available, read it via the relative path the server
          // already knows — otherwise fall back to the server picker.
          this.resolvePath = async (handle) => {
            try {
              // queryPermission/requestPermission only exist on directory
              // handles in Chromium; if absent, we cannot recover the path.
              if (!handle.queryPermission) return '';
              const ok = await handle.queryPermission({ mode: 'read' });
              if (ok !== 'granted') return '';
              // Chromium does not expose the absolute path; a common workaround
              // is to read the handle's name and let the server resolve it via
              // the last known cwd. We pass the name and let picker fall back.
              return handle.name || '';
            } catch (_) {
              return '';
            }
          };
          this.el.addEventListener('click', this.onClick);
        },
        destroyed() {
          this.el.removeEventListener('click', this.onClick);
        }
      });
    </script>

    <script data-phx-runtime-hook="WsGroupNew">
      window.phx_hook_WsGroupNew = () => ({
        mounted() {
          this.onClick = (e) => {
            e.preventDefault();
            e.stopPropagation();
            const repo = this.el.dataset.repo || '';
            const title = window.prompt('Session name (optional)', '');
            this.pushEvent('workspace_create', { repo: repo, title: title || '' });
          };
          this.el.addEventListener('click', this.onClick);
        },
        destroyed() {
          this.el.removeEventListener('click', this.onClick);
        }
      });
    </script>

    <script data-phx-runtime-hook="WorkspaceMenu">
      window.phx_hook_WorkspaceMenu = () => ({
        mounted() {
          this.toggleBtn = this.el.querySelector('.ws-meatball');
          this.menu = this.el.querySelector('.ws-menu');
          this.open = false;
          this.onToggle = (e) => {
            e.preventDefault();
            e.stopPropagation();
            if (this.open) { this.close(); } else { this.openMenu(); }
          };
          this.onItem = (e) => {
            e.preventDefault();
            e.stopPropagation();
            const item = e.target.closest('[data-action]');
            const session = this.el.dataset.session || '';
            if (item && item.dataset.action === 'close') {
              this.pushEvent('workspace_close', { session: session });
            } else if (item && item.dataset.action === 'rename') {
              const title = window.prompt('Session name', this.el.dataset.title || '');
              if (title !== null && title.trim() !== '') {
                this.pushEvent('workspace_rename', { session: session, title: title.trim() });
              }
            }
            this.close();
          };
          this.onDoc = (e) => { if (!this.el.contains(e.target)) this.close(); };
          this.onKey = (e) => { if (e.key === 'Escape') this.close(); };
          this.toggleBtn.addEventListener('click', this.onToggle);
          this.menu.addEventListener('click', this.onItem);
          document.addEventListener('click', this.onDoc);
          document.addEventListener('keydown', this.onKey);
        },
        updated() { this.close(); },
        destroyed() {
          if (this.toggleBtn) this.toggleBtn.removeEventListener('click', this.onToggle);
          if (this.menu) this.menu.removeEventListener('click', this.onItem);
          document.removeEventListener('click', this.onDoc);
          document.removeEventListener('keydown', this.onKey);
        },
        openMenu() {
          this.open = true;
          this.el.classList.add('open');
          this.menu.hidden = false;
          this.toggleBtn.setAttribute('aria-expanded', 'true');
        },
        close() {
          if (!this.open) return;
          this.open = false;
          this.el.classList.remove('open');
          this.menu.hidden = true;
          this.toggleBtn.setAttribute('aria-expanded', 'false');
        }
      });
    </script>
    """
  end

  defp result_label({:ok, _session}), do: "session created"
  defp result_label(:ok), do: "session closed"
  defp result_label({:error, reason}), do: "error: " <> inspect(reason)
  defp result_label(other), do: inspect(other)
end
