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

    ui_slot(:main, kind: :list, order: 10, component: {__MODULE__, :panel, []})

    def panel(assigns) do
      ~H"""
      <section>
        <h2>chat</h2>
        <div class="chat">
          <ul>
            <%= for {role, content} <- @chat_log do %>
              <li><strong><%= role %></strong>: <code><%= content %></code></li>
            <% end %>
            <%= if @chat_error do %>
              <li><strong>error</strong>: <code><%= @chat_error %></code></li>
            <% end %>
            <%= if @chat_busy do %>
              <li><strong>…</strong>: <code>thinking (model round-trip)</code></li>
            <% end %>
          </ul>
        </div>
        <form class="row" phx-submit="ask">
          <input type="text" name="text" value={@chat_text} placeholder="run a task (drives the agent loop)" style="flex:1" disabled={@chat_busy} />
          <button type="submit" disabled={@chat_busy}>ask</button>
          <button type="button" phx-click="clear_chat">new conversation</button>
        </form>
      </section>
      """
    end
  end

  defmodule Todo do
    @moduledoc false
    use DshBeam.Plugin
    import Phoenix.Component

    ui_slot(:main, kind: :list, order: 40, component: {__MODULE__, :panel, []})

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
      ~H"""
      <section>
        <h2>llm settings</h2>
        <%= if @llm_config do %>
          <form phx-submit="llm_apply">
            <label class="muted">base_url</label>
            <input type="text" name="base_url" value={@llm_config.base_url} />
            <label class="muted">model</label>
            <input type="text" name="model" value={@llm_config.model} />
            <label class="muted">credential</label>
            <select name="credential_mode">
              <option value="env" selected={@credential_mode == "env"}>env</option>
              <option value="literal" selected={@credential_mode == "literal"}>api key (literal)</option>
            </select>
            <input
              type="text"
              name="credential_value"
              value={@credential_env}
              placeholder={
                if @credential_mode == "env",
                  do: "env var name (e.g. DEEPSEEK_API_KEY)",
                  else: "paste API key (blank keeps current)"
              }
            />
            <button type="submit">apply</button>
          </form>
          <p class="muted">leave the credential field blank to keep the current key · result: <code><%= inspect(@llm_result) %></code></p>
        <% else %>
          <p class="muted">no :llm provider (seed the demo composition)</p>
        <% end %>
      </section>
      """
    end
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
        <div class="scroll">
          <%= for plugin <- @inventory do %>
            <div style="border-top:1px solid #20262f; padding:6px 0">
              <strong><%= plugin.name %></strong>
              <span class={"pill state-#{if plugin.enabled, do: "active", else: "gone"}"}>
                <%= if plugin.enabled, do: "enabled", else: "disabled" %>
              </span>
              <%= if plugin.settings != [] do %>
                <form phx-submit="settings_save" class="row">
                  <input type="hidden" name="plugin" value={to_string(plugin.plugin)} />
                  <%= for setting <- plugin.settings do %>
                    <label class="muted" title={setting.doc}><%= setting.name %></label>
                    <input type="text" name={"settings[#{setting.name}]"} value={setting.display} />
                  <% end %>
                  <button type="submit">save</button>
                </form>
              <% end %>
            </div>
          <% end %>
        </div>
      </section>
      """
    end
  end
end
