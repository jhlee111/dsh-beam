defmodule DshBeam.Ui.Panel.Workspace do
  @moduledoc """
  The workspace sidebar: lists the workspace's sessions (each a git worktree),
  creates new ones, switches the current session, and closes them. A session is
  the unit of the chat/todo/trajectory panes — switching rebinds `:session` to
  the selected worktree.
  """

  use DshBeam.Plugin
  import Phoenix.Component

  ui_slot(:panels, kind: :list, order: 5, component: {__MODULE__, :panel, []})

  def panel(assigns) do
    ~H"""
    <section>
      <h2>workspace</h2>

      <form class="row" phx-submit="workspace_create">
        <input type="text" name="repo" value={@workspace_repo} placeholder="repository path" style="flex:1" />
        <input type="text" name="title" placeholder="title (optional)" />
        <button type="submit">new session</button>
      </form>
      <p class="muted">result: <code><%= inspect(@workspace_result) %></code></p>

      <ul>
        <%= if @workspace_sessions == [] do %>
          <li class="muted">no sessions — open one over a git repository</li>
        <% end %>
        <%= for s <- @workspace_sessions do %>
          <li style="display:flex; gap:6px; align-items:center; justify-content:space-between">
            <span>
              <span class={"pill state-#{if s.current, do: "active", else: "gone"}"}>
                <%= if s.current, do: "current", else: "idle" %>
              </span>
              <code><%= s.title %></code>
              <span class="muted">· <%= s.cwd %></span>
            </span>
            <span>
              <%= unless s.current do %>
                <button phx-click="workspace_switch" phx-value-session={s.session_key}>switch</button>
              <% end %>
              <button phx-click="workspace_close" phx-value-session={s.session_key}>close</button>
            </span>
          </li>
        <% end %>
      </ul>
    </section>
    """
  end
end
