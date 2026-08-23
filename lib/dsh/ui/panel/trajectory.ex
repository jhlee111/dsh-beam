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

  ui_slot(:conversation,
    kind: :keyed,
    order: 30,
    key: :trajectory,
    component: {__MODULE__, :panel, []}
  )

  def panel(assigns) do
    ~H"""
    <section>
      <h2>trajectory</h2>
      <div class="scroll">
        <%= if @trajectory == [] do %>
          <p class="muted">no turns yet — the chat pane appends them</p>
        <% end %>
        <%= for {turn, index} <- Enum.with_index(@trajectory) do %>
          <div class="trajectory-turn">
            <strong class="muted">turn <%= index + 1 %></strong>
            <div class="chat-flow">
              <%= for entry <- turn do %>
                <DshBeam.Ui.ChatEntry.render entry={entry} />
              <% end %>
            </div>
          </div>
        <% end %>
      </div>
    </section>
    """
  end
end
