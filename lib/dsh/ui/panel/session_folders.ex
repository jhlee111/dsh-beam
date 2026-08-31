defmodule DshBeam.Ui.Panel.SessionFolders do
  @moduledoc """
  The composer "folder+" seat — a session-scoped extra-folders button.

  Extra folder access is a safety measure: a session only sees its own
  workspace code by default; an extra folder lets the agent read it, and —
  when added as writable — write to it. The folder belongs to the SESSION
  (not the workspace, not the whole disk): it is stored on the session via
  `DshBeam.Workspace.set_session_folders/3` and resolved per-session by
  `DshBeam.Tool.Fs`.

  Clicking 📁+ opens the browser's native directory picker
  (`showDirectoryPicker`, folders only) and adds the chosen folder to the
  current session as WRITABLE (same as `/folders add -w <path>`). The
  picker falls back to the server-side browse dialog when unavailable.
  """

  use DshBeam.Plugin
  import Phoenix.Component

  ui_slot(:composer_toolbar, kind: :list, order: 7, component: {__MODULE__, :panel, []})

  def panel(assigns) do
    ~H"""
    <div class="sf-seat" id="sf-seat" phx-hook="SessionFolderAdd">
      <button
        type="button"
        class="sf-trigger"
        aria-label="add an extra folder this session may read/write"
        title="add an extra folder for this session (browser folder picker)"
        disabled={@chat_busy}
      >
        <span class="sf-icon">📁</span><span class="sf-plus">+</span>
      </button>

      <style>
        .sf-seat { position: relative; display: inline-flex; }
        .sf-trigger {
          display: inline-flex; align-items: center; gap: 2px; height: 28px;
          padding: 0 8px; border-radius: 24px;
          border: 1px solid var(--dsw-alias-border-l2);
          background: transparent; color: var(--dsw-alias-label-secondary);
          font-size: 13px; line-height: 20px; cursor: pointer;
        }
        .sf-trigger:hover:not(:disabled) { background: var(--dsw-alias-interactive-bg-hover); }
        .sf-trigger:disabled { color: var(--dsw-alias-label-dimmed); cursor: default; }
        .sf-icon { font-size: 14px; line-height: 1; }
        .sf-plus { font-size: 13px; font-weight: 700; line-height: 1; color: var(--dsw-static-deepseek-400, #679efe); }
      </style>

      <script data-phx-runtime-hook="SessionFolderAdd">
        window.phx_hook_SessionFolderAdd = () => ({
          mounted() {
            this.onClick = async (e) => {
              e.preventDefault();
              e.stopPropagation();
              if (this.el.querySelector('.sf-trigger').disabled) return;
              if (window.showDirectoryPicker) {
                try {
                  const handle = await window.showDirectoryPicker({ mode: 'read' });
                  const path = handle.name || '';
                  if (path) this.pushEvent('session_folder_add', { path: path });
                } catch (err) {
                  if (err && err.name === 'AbortError') return; // user cancelled
                }
              } else {
                this.pushEvent('session_folder_browse', {});
              }
            };
            this.el.addEventListener('click', this.onClick);
          },
          destroyed() {
            this.el.removeEventListener('click', this.onClick);
          }
        });
      </script>
    </div>
    """
  end
end
