defmodule DshBeam.Ui.Panel.Trajectory do
  @moduledoc """
  The trajectory view: the session log grouped by turn (a `user` event starts a
  turn; the tool calls, results, and the assistant answer follow it). It is a
  different projection of the same session log the chat pane renders — the
  reference `ui-trajectory`, as a plugin.

  The grouping lives in the console's assigns (`@trajectory`), so this panel is
  a pure render of that projection.
  """

  use DshBeam.Plugin
  import Phoenix.Component

  ui_slot(:panels, kind: :list, order: 35, component: {__MODULE__, :panel, []})

  def panel(assigns) do
    ~H"""
    <section>
      <h2>trajectory</h2>
      <%= if @trajectory == [] do %>
        <p class="muted">no turns yet — the chat pane appends them</p>
      <% end %>
      <%= for {turn, index} <- Enum.with_index(@trajectory) do %>
        <div style="border-top:1px solid #20262f; padding:6px 0">
          <strong class="muted">turn <%= index + 1 %></strong>
          <ul>
            <%= for {role, content} <- turn do %>
              <li><strong><%= role %></strong>: <code><%= content %></code></li>
            <% end %>
          </ul>
        </div>
      <% end %>
    </section>
    """
  end
end
