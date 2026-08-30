defmodule DshBeam.Ui.Panel.WorkspaceFolders do
  @moduledoc """
  The "extra folders" seat in the workspace sidebar — the cloud-code-style
  capability of adding a few related folders (not the whole disk) the agent
  may read — and, when marked writable, write — outside the session worktree.

  The list is the `:extra_folders` typed setting of `DshBeam.WorkspaceFolders`
  (persisted to the settings store), so it survives a restart; the console's
  `workspace_folders_add`/`workspace_folders_remove` handlers re-arm the
  plugin after every change and the `DshBeam.Tool.Fs` tool resolves file
  paths against these roots at call time. A read-only folder (the `r` prefix)
  refuses writes.
  """

  use DshBeam.Plugin
  import Phoenix.Component

  ui_slot(:sidebar, kind: :list, order: 20, component: {__MODULE__, :panel, []})

  def panel(assigns) do
    ~H"""
    <section class="wf-panel">
      <h2>extra folders</h2>
      <p class="muted wf-hint">
        folders the agent may read/write alongside the session workspace
      </p>

      <div class="workspace-list wf-list">
        <%= if @workspace_folders == [] do %>
          <p class="muted empty-hint">none yet — add a folder to let the agent reach it</p>
        <% end %>
        <%= for f <- @workspace_folders do %>
          <div class="workspace-row wf-row">
            <span class="ws-dot idle" title={if f.writable, do: "writable", else: "read-only"}></span>
            <div class="workspace-meta">
              <span class="ws-cwd" title={f.path}><%= f.path %></span>
              <span class={"pill #{if f.writable, do: "state-active", else: "state-gone"}"}>
                <%= if f.writable, do: "writable", else: "read-only" %>
              </span>
            </div>
            <div class="workspace-actions">
              <button phx-click="workspace_folders_remove" phx-value-path={f.path}>remove</button>
            </div>
          </div>
        <% end %>
      </div>

      <form class="workspace-form" phx-submit="workspace_folders_add">
        <label class="muted" for="wf-path">folder path</label>
        <input
          type="text"
          name="path"
          id="wf-path"
          value={@wf_draft}
          placeholder={"/abs/path/to/related/repo"}
        />
        <label class="wf-check">
          <input type="checkbox" name="writable" value="true" checked={@wf_writable} />
          writable (else read-only)
        </label>
        <button type="submit" class="new-session-btn">+ add folder</button>
      </form>

      <%= if @wf_result do %>
        <p class="workspace-feedback muted"><%= @wf_result %></p>
      <% end %>
    </section>
    """
  end
end
