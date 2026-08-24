defmodule DshBeam.Ui.Panel.Access do
  @moduledoc """
  The composer "Access" seat — the reference `PermissionSelect`: a chip that
  shows the current permission preset, a dropdown of the three presets, and a
  checkbox-gated risk confirmation before enabling Full access.

  It renders into the `:composer_toolbar` slot (a `:list` slot the shell owns),
  so adding or removing this plugin is adding or removing the seat — never an
  edit to the shell. The value shape comes from `DshBeam.Permission.select_for/1`
  (computed by the console into `@permission`), and the open/confirm state lives
  in the LiveView's assigns (`@permission_open`, `@permission_confirming`,
  `@permission_acknowledged`).
  """

  use DshBeam.Plugin
  import Phoenix.Component

  ui_slot(:composer_toolbar, kind: :list, order: 10, component: {__MODULE__, :panel, []})

  def panel(assigns) do
    ~H"""
    <div class="access-seat">
      <button
        type="button"
        class="access-trigger"
        phx-click="permission_toggle"
        aria-haspopup="menu"
        aria-expanded={@permission_open}
        disabled={@chat_busy}
      >
        <span class="access-icon">
          <DshBeamWeb.Icons.shield mode={shield_mode(@permission.current_value)} />
        </span>
        <span class="access-label"><%= current_name(@permission) %></span>
        <DshBeamWeb.Icons.chevron_down class={"access-chevron #{if @permission_open, do: "open"}"} />
      </button>

      <%= if @permission_open do %>
        <div class="access-menu" role="menu">
          <%= for opt <- @permission.options do %>
            <button
              type="button"
              role="menuitemradio"
              aria-checked={opt.value == @permission.current_value}
              class={"access-option #{if opt.value == @permission.current_value, do: "selected"}"}
              phx-click="permission_select"
              phx-value-preset={opt.value}
            >
              <span class="access-icon">
                <DshBeamWeb.Icons.shield mode={shield_mode(opt.value)} />
              </span>
              <span class="access-opt-label" title={opt.description}><%= opt.name %></span>
              <%= if opt.value == @permission.current_value do %>
                <DshBeamWeb.Icons.check class="access-check" />
              <% end %>
            </button>
          <% end %>
        </div>
      <% end %>
    </div>

    <%= if @permission_confirming do %>
      <div class="settings-overlay">
        <div class="settings-backdrop" phx-click="permission_cancel"></div>
        <div class="settings-panel access-confirm">
          <div class="access-confirm-body">
            <h2>Enable Full access?</h2>
            <p class="muted">
              Full access reduces confirmation steps and lets the agent perform more actions
              directly, including sensitive operations, file changes, or external commands.
              Only use it when you trust the current task.
            </p>
            <button type="button" class="access-ack" phx-click="permission_ack">
              <span class={"ack-box #{if @permission_acknowledged, do: "checked"}"} aria-hidden="true">
                <%= if @permission_acknowledged, do: "✓" %>
              </span>
              <span>I understand the risks and want to continue</span>
            </button>
            <div class="access-confirm-actions">
              <button type="button" phx-click="permission_cancel">Cancel</button>
              <button
                type="button"
                class="access-confirm-enable"
                phx-click="permission_confirm"
                disabled={not @permission_acknowledged}
              >
                Enable Full access
              </button>
            </div>
          </div>
        </div>
      </div>
    <% end %>
    """
  end

  defp shield_mode("danger-full-access"), do: :full_access
  defp shield_mode("workspace-write"), do: :workspace_write
  defp shield_mode("read-only"), do: :read_only
  defp shield_mode(_), do: :workspace_write

  defp current_name(%{current_value: value, options: options}) do
    case Enum.find(options, &(&1.value == value)) do
      nil -> value
      option -> option.name
    end
  end
end
