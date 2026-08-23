defmodule DshBeam.Ui.Panel do
  @moduledoc """
  The console's built-in UI panels, each a plugin that registers one
  contribution to the `:panels` slot (`kind: :list`). A panel is a function
  component that reads the console's `assigns` — so adding or removing a panel
  is adding or removing a plugin from the composition, not editing the layout.
  """

  defmodule Composition do
    @moduledoc false
    use DshBeam.Plugin
    import Phoenix.Component

    ui_slot(:settings_section,
      kind: :keyed,
      order: 40,
      key: :composition,
      component: {__MODULE__, :panel, []}
    )

    def panel(assigns) do
      ~H"""
      <section>
        <h2>composition</h2>
        <form class="row" phx-submit="seed">
          <button type="submit">seed demo (session + llm + chat)</button>
        </form>
        <div class="scroll">
          <table>
            <thead>
              <tr>
                <th>id</th><th>plugin</th><th>fiber</th><th>pid</th><th>restarts</th><th>error</th><th>os_pid</th><th></th>
              </tr>
            </thead>
            <tbody>
              <%= for row <- @rows do %>
                <tr>
                  <td><code><%= inspect(row.id) %></code></td>
                  <td class="muted"><%= row.plugin %></td>
                  <td><span class={"pill state-#{row.state}"}><%= row.state %></span></td>
                  <td class="muted"><%= inspect(row.pid) %></td>
                  <td><%= row.restarts %></td>
                  <td class="muted"><%= inspect(row.error) %></td>
                  <td class="muted"><%= inspect(row.os_pid) %></td>
                  <td>
                    <button phx-click="kill" phx-value-id={row.id_key}>kill</button>
                    <%= if row.sandboxed do %>
                      <button phx-click="crash_child" phx-value-id={row.id_key}>crash child</button>
                    <% end %>
                    <button phx-click="remove" phx-value-id={row.id_key}>remove</button>
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
        <p class="muted">kill = external kill (recorded, not re-injected). crash child = sandbox SIGKILL (guard + re-injection).</p>
      </section>
      """
    end
  end

  defmodule Bindings do
    @moduledoc false
    use DshBeam.Plugin
    import Phoenix.Component

    ui_slot(:settings_section,
      kind: :keyed,
      order: 50,
      key: :bindings,
      component: {__MODULE__, :panel, []}
    )

    def panel(assigns) do
      ~H"""
      <section>
        <h2>bindings</h2>
        <table>
          <thead><tr><th>key</th><th>value</th></tr></thead>
          <tbody>
            <%= for {key, value} <- @bindings do %>
              <tr><td><code><%= inspect(key) %></code></td><td class="muted"><%= inspect(value) %></td></tr>
            <% end %>
          </tbody>
        </table>
      </section>
      """
    end
  end

  defmodule Chat do
    @moduledoc false
    use DshBeam.Plugin
    import Phoenix.Component

    ui_slot(:conversation,
      kind: :keyed,
      order: 10,
      key: :chat,
      component: {__MODULE__, :panel, []}
    )

    def panel(assigns) do
      ~H"""
      <div class="chat-view">
        <div class="chat-flow">
          <%= for entry <- @chat_log do %>
            <DshBeam.Ui.ChatEntry.render entry={entry} />
          <% end %>
          <%= if @chat_error do %>
            <div class="msg-error"><code><%= @chat_error %></code></div>
          <% end %>
          <%= if @chat_busy do %>
            <div class="msg-busy muted">thinking (model round-trip)…</div>
          <% end %>
        </div>
      </div>
      """
    end
  end

  defmodule Todo do
    @moduledoc false
    use DshBeam.Plugin
    import Phoenix.Component

    ui_slot(:details, kind: :list, order: 40, component: {__MODULE__, :panel, []})

    def panel(assigns) do
      ~H"""
      <section>
        <h2>todo</h2>
        <ul>
          <%= if @todos == [] do %>
            <li class="muted">no plan yet (the agent writes it via todo_write)</li>
          <% end %>
          <%= for todo <- @todos do %>
            <li>
              <span class={"pill state-#{status_class(todo["status"])}"}><%= todo["status"] %></span>
              <code><%= todo["content"] %></code>
            </li>
          <% end %>
        </ul>
      </section>
      """
    end

    defp status_class("completed"), do: "active"
    defp status_class("in_progress"), do: "reloading"
    defp status_class(_), do: "gone"
  end

  defmodule LlmSettings do
    @moduledoc false
    use DshBeam.Plugin
    import Phoenix.Component

    ui_slot(:settings_section,
      kind: :keyed,
      order: 10,
      key: :models,
      component: {__MODULE__, :panel, []}
    )

    def panel(assigns) do
      assigns =
        assigns
        |> assign(:provider, provider_name(assigns.llm_config))
        |> assign(:credential_configured, credential_configured?(assigns.llm_config))

      ~H"""
      <section>
        <h2>models</h2>
        <%= if @llm_config do %>
          <div class="provider-card">
            <div class="provider-head">
              <span class="provider-name"><%= @provider %></span>
              <span
                class={"credential-dot #{if @credential_configured, do: "configured", else: "missing"}"}
                title={if @credential_configured, do: "credential configured", else: "credential missing"}
              >
                <%= if @credential_configured, do: "key set", else: "no key" %>
              </span>
              <span class="muted">route: deepseek</span>
            </div>
            <form phx-submit="llm_apply">
              <label class="muted">api key</label>
              <div class="key-row">
                <select name="credential_mode">
                  <option value="env" selected={@credential_mode == "env"}>env ref</option>
                  <option value="literal" selected={@credential_mode == "literal"}>literal key</option>
                </select>
                <input
                  type="password"
                  name="credential_value"
                  value={@credential_env}
                  placeholder={
                    if @credential_mode == "env",
                      do: "env var name (e.g. DEEPSEEK_API_KEY)",
                      else: "paste API key (blank keeps current)"
                  }
                />
              </div>
              <details>
                <summary>customized settings</summary>
                <label class="muted">base_url</label>
                <input type="text" name="base_url" value={@llm_config.base_url} />
                <label class="muted">model</label>
                <input type="text" name="model" value={@llm_config.model} />
              </details>
              <div class="provider-actions">
                <button type="submit">apply</button>
                <span class="muted">leave the key blank to keep the current one</span>
              </div>
            </form>
          </div>
          <p class="muted">result: <code><%= @llm_result %></code></p>
        <% else %>
          <p class="muted">no :llm provider (seed the demo composition)</p>
        <% end %>
      </section>
      """
    end

    defp provider_name(nil), do: "deepseek"

    defp provider_name(%{base_url: base_url}) do
      case URI.parse(base_url || "") do
        %{host: host} when is_binary(host) and host != "" ->
          if String.contains?(host, "deepseek"), do: "DeepSeek", else: host

        _ ->
          "deepseek"
      end
    end

    defp credential_configured?(nil), do: false
    defp credential_configured?(%{credential: credential}), do: credential != nil
  end

  defmodule Creator do
    @moduledoc false
    use DshBeam.Plugin
    import Phoenix.Component

    ui_slot(:settings_section,
      kind: :keyed,
      order: 70,
      key: :creator,
      component: {__MODULE__, :panel, []}
    )

    def panel(assigns) do
      ~H"""
      <section>
        <h2>creator / sandbox</h2>
        <form phx-submit="define">
          <select name="mode">
            <option value="trusted" selected={@mode == "trusted"}>trusted (Creator, in-process)</option>
            <option value="sandbox" selected={@mode == "sandbox"}>sandbox (child OS process)</option>
          </select>
          <textarea name="source"><%= @source %></textarea>
          <button type="submit">define</button>
          <button type="button" phx-click="export_plugin">export plugin (.exs)</button>
        </form>
        <p class="muted">result: <code><%= inspect(@result) %></code></p>
      </section>
      """
    end
  end

  defmodule EventFeed do
    @moduledoc false
    use DshBeam.Plugin
    import Phoenix.Component

    ui_slot(:settings_section,
      kind: :keyed,
      order: 60,
      key: :events,
      component: {__MODULE__, :panel, []}
    )

    def panel(assigns) do
      ~H"""
      <section>
        <h2>event feed</h2>
        <div class="events">
          <ul>
            <%= for event <- @events do %>
              <li><code><%= inspect(event) %></code></li>
            <% end %>
          </ul>
        </div>
      </section>
      """
    end
  end

  defmodule Plugins do
    @moduledoc false
    use DshBeam.Plugin
    import Phoenix.Component

    ui_slot(:settings_section,
      kind: :keyed,
      order: 20,
      key: :plugins,
      component: {__MODULE__, :panel, []}
    )

    def panel(assigns) do
      ~H"""
      <section>
        <h2>plugins</h2>
        <%= if @plugins_result do %>
          <p class="muted"><%= @plugins_result %></p>
        <% end %>
        <div class="plugins-scroll">
          <%= for p <- @inventory do %>
            <div class="plugin-card">
              <button
                type="button"
                class="plugin-head"
                phx-click="plugin_toggle"
                phx-value-plugin={inspect(p.plugin)}
              >
                <span class="plugin-name"><%= p.name %></span>
                <span class={"pill state-#{if p.enabled, do: "active", else: "gone"}"}>
                  <%= if p.enabled, do: "enabled", else: "disabled" %>
                </span>
                <%= if p.settings != [] do %>
                  <span class="plugin-desc"><%= p.desc %></span>
                  <%= if p.dirty do %>
                    <span class="pill unsaved">unsaved</span>
                  <% end %>
                  <span class={"chevron #{if p.open, do: "open"}"}>▾</span>
                <% end %>
              </button>
              <%= if p.open and p.settings != [] do %>
                <form class="plugin-body" phx-change="plugin_edit" phx-submit="settings_save">
                  <input type="hidden" name="plugin" value={to_string(p.plugin)} />
                  <%= for s <- p.settings do %>
                    <label class="muted" title={s.doc}><%= s.name %></label>
                    <input type="text" name={"settings[#{s.name}]"} value={s.text} />
                  <% end %>
                  <div class="plugin-actions">
                    <button type="submit">save</button>
                    <button
                      type="button"
                      phx-click="plugin_discard"
                      phx-value-plugin={inspect(p.plugin)}
                    >
                      discard
                    </button>
                  </div>
                </form>
              <% end %>
            </div>
          <% end %>
        </div>
      </section>
      """
    end
  end

  defmodule General do
    @moduledoc false
    use DshBeam.Plugin
    import Phoenix.Component

    setting(:default_preset,
      type: :string,
      default: "demo",
      doc: "Agent preset new sessions start from"
    )

    setting(:workspace_default_root,
      type: :string,
      default: ".",
      doc: "Default repository root for new session worktrees"
    )

    ui_slot(:settings_section,
      kind: :keyed,
      order: 5,
      key: :general,
      component: {__MODULE__, :panel, []}
    )

    def panel(assigns) do
      ~H"""
      <section>
        <h2>general</h2>
        <form class="general-form" phx-submit="settings_save">
          <input type="hidden" name="plugin" value={to_string(DshBeam.Ui.Panel.General)} />
          <label class="muted">default preset</label>
          <select name="settings[default_preset]">
            <%= for p <- @presets do %>
              <option value={p.id} selected={p.default}><%= p.name %></option>
            <% end %>
          </select>
          <label class="muted">workspace default root</label>
          <input type="text" name="settings[workspace_default_root]" value={@workspace_default_root} />
          <button type="submit">save</button>
        </form>
        <%= if @plugins_result do %>
          <p class="muted"><%= @plugins_result %></p>
        <% end %>
      </section>
      """
    end
  end

  defmodule Presets do
    @moduledoc false
    use DshBeam.Plugin
    import Phoenix.Component

    ui_slot(:settings_section,
      kind: :keyed,
      order: 6,
      key: :presets,
      component: {__MODULE__, :panel, []}
    )

    def panel(assigns) do
      ~H"""
      <section>
        <h2>agent presets</h2>
        <%= if @presets_result do %>
          <p class="muted"><%= @presets_result %></p>
        <% end %>
        <form class="row" phx-submit="preset_copy">
          <select name="preset">
            <%= for p <- @presets do %>
              <option value={p.id}><%= p.name %></option>
            <% end %>
          </select>
          <input type="text" name="name" placeholder="new preset name" />
          <button type="submit">duplicate</button>
        </form>
        <div class="preset-list">
          <%= for p <- @presets do %>
            <div class={"preset-card #{if p.default, do: "preset-default"}"}>
              <div class="preset-head">
                <span class="preset-name"><%= p.name %></span>
                <span class="pill"><%= if p.builtin, do: "built-in", else: "custom" %></span>
                <%= if p.default do %>
                  <span class="pill state-active">default</span>
                <% end %>
              </div>
              <p class="muted"><%= p.desc %></p>
              <code class="preset-id"><%= p.id %></code>
              <div class="preset-actions">
                <button phx-click="preset_default" phx-value-preset={p.id} disabled={p.default}>
                  set default
                </button>
                <button phx-click="preset_apply" phx-value-preset={p.id}>apply</button>
                <%= if not p.builtin do %>
                  <button phx-click="preset_delete" phx-value-preset={p.id}>delete</button>
                <% end %>
              </div>
            </div>
          <% end %>
        </div>
      </section>
      """
    end
  end
end
