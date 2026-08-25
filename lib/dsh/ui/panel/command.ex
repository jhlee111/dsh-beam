defmodule DshBeam.Ui.Panel.Command do
  @moduledoc """
  The composer's command menu — the reference's "＋" trigger and slash-command
  directory. A "+" button opens a dropdown of `DshBeam.Command.catalog/0`;
  picking one writes the `/name ` claim token into the composer draft, which the
  user then completes and submits (the console routes it through
  `run_command/3`). Renders into the `:composer_toolbar` slot.
  """

  use DshBeam.Plugin
  import Phoenix.Component

  ui_slot(:composer_toolbar, kind: :list, order: 5, component: {__MODULE__, :panel, []})

  def panel(assigns) do
    ~H"""
    <div class="command-seat">
      <button
        type="button"
        class="command-trigger"
        phx-click="command_toggle"
        aria-label="commands"
        aria-haspopup="menu"
        aria-expanded={@command_open}
        disabled={@chat_busy}
      >
        <DshBeamWeb.Icons.plus />
      </button>

      <%= if @command_open do %>
        <div class="command-menu" role="menu">
          <%= for name <- DshBeam.Command.names() do %>
            <% cmd = DshBeam.Command.find(name) %>
            <button
              type="button"
              role="menuitem"
              class="command-option"
              phx-click="command_pick"
              phx-value-command={name}
            >
              <span class="command-option-name">/<%= name %></span>
              <span class="command-option-desc"><%= cmd.description %></span>
            </button>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end
end
