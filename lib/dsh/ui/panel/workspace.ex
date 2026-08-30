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
      <h2>workspace</h2>

      <form class="workspace-form" phx-submit="workspace_create">
        <input type="hidden" name="repo" value={@workspace_repo} />
        <label class="muted">workspace folder</label>
        <div class="repo-picker">
          <code class="repo-path"><%= @workspace_repo %></code>
          <button type="button" phx-click="browse_dir">browse</button>
        </div>
        <label class="muted" for="ws-title">session title (optional)</label>
        <input type="text" name="title" id="ws-title" placeholder="e.g. my task" />
        <label class="wf-check ws-worktree-check" title="off: open the session in-place, not as a git worktree">
          <input type="checkbox" name="worktree" value="true" checked />
          git worktree
        </label>
        <button type="submit" class="new-session-btn">+ new session</button>
      </form>

      <%= if @workspace_result do %>
        <p class="workspace-feedback muted"><%= result_label(@workspace_result) %></p>
      <% end %>

      <div class="workspace-list">
        <%= if @workspace_sessions == [] do %>
          <p class="muted empty-hint">
            no sessions yet — pick a workspace folder and press “+ new session”
          </p>
        <% end %>
        <%= for {s, idx} <- Enum.with_index(@workspace_sessions) do %>
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
                id={"ws-menu-" <> Integer.to_string(idx)}
                class="ws-menu-wrap"
                phx-hook="WorkspaceMenu"
                data-session={s.session_key}
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
    </section>

    <style>
      /* The whole card is the switch target (non-current rows); the only
         visible control is a vertical meatball revealed on hover. Closing is
         a two-step path — ⋮ → close session — so it can't be hit by accident. */
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
            if (item && item.dataset.action === 'close') {
              const session = this.el.dataset.session || '';
              this.pushEvent('workspace_close', { session: session });
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
