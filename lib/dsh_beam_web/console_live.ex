defmodule DshBeamWeb.ConsoleLive do
  @moduledoc """
  The console view: the live composition (entries, fiber states, bindings,
  event feed), a creator/sandbox source editor, and a chat pane over the
  session + llm plugins.

  Updates are reactive, not polled: the LiveView subscribes to the context
  and runtime event streams (DshBeam.Context.subscribe / DshBeam.Runtime.subscribe)
  and re-renders on every state change.
  """

  use Phoenix.LiveView

  import Phoenix.Component

  @default_source """
  defmodule MadeProvider do
    use DshBeam.Plugin
    provide :made, value: 42
  end
  """

  @demo_entries [
    %{id: :session, plugin: DshBeam.Session.Plugin, config: [], disabled: false},
    %{id: :llm, plugin: DshBeam.Llm.Plugin, config: [], disabled: false},
    %{id: :shell, plugin: DshBeam.Shell.Plugin, config: [], disabled: false},
    %{id: :bash, plugin: DshBeam.Tool.Bash, config: [], disabled: false},
    %{id: :fs, plugin: DshBeam.Tool.Fs, config: [root: "."], disabled: false},
    %{id: :loop, plugin: DshBeam.Agent.Loop, config: [], disabled: false}
  ]

  @impl true
  def mount(_params, session, socket) do
    %{runtime: runtime, ctx: ctx} = refs(session)

    :ok = DshBeam.Context.subscribe(ctx)
    :ok = DshBeam.Runtime.subscribe(runtime)

    socket =
      socket
      |> assign(:runtime, runtime)
      |> assign(:ctx, ctx)
      |> assign(:source, @default_source)
      |> assign(:mode, "trusted")
      |> assign(:result, nil)
      |> assign(:chat_text, "")
      |> assign(:chat_log, [])
      |> assign(:chat_busy, false)
      |> assign(:events, [])
      |> assign(:rows, [])
      |> assign(:bindings, %{})
      |> assign(:llm_config, nil)
      |> assign(:llm_result, nil)
      |> assign(:credential_mode, "env")
      |> assign(:credential_env, "DEEPSEEK_API_KEY")
      |> assign(:inventory, [])
      |> refresh()

    {:ok, socket}
  end

  @impl true
  def handle_event("define", %{"source" => source, "mode" => mode}, socket) do
    result =
      case mode do
        "sandbox" -> DshBeam.Sandbox.define(socket.assigns.runtime, source)
        _ -> DshBeam.Creator.define(socket.assigns.runtime, source)
      end

    {:noreply, socket |> assign(source: source, result: inspect(result)) |> refresh()}
  end

  def handle_event("remove", %{"id" => id_key}, socket) do
    id = decode_id!(socket.assigns.runtime, id_key)

    :ok =
      DshBeam.Runtime.reconcile(socket.assigns.runtime, reject_spec(socket.assigns.runtime, id))

    {:noreply, refresh(socket)}
  end

  def handle_event("kill", %{"id" => id_key}, socket) do
    id = decode_id!(socket.assigns.runtime, id_key)

    case DshBeam.Runtime.entries(socket.assigns.runtime) do
      %{^id => %{pid: pid}} when is_pid(pid) -> Process.exit(pid, :kill)
      _ -> :ok
    end

    {:noreply, refresh(socket)}
  end

  def handle_event("crash_child", %{"id" => id_key}, socket) do
    id = decode_id!(socket.assigns.runtime, id_key)

    case DshBeam.Runtime.entries(socket.assigns.runtime) do
      %{^id => %{pid: pid}} when is_pid(pid) -> DshBeam.Sandbox.Plugin.kill_child(pid)
      _ -> :ok
    end

    {:noreply, refresh(socket)}
  end

  def handle_event("seed", _params, socket) do
    specs =
      socket.assigns.runtime
      |> current_specs()
      |> Enum.reject(&(&1.id in [:session, :llm, :shell, :bash, :fs, :loop]))

    :ok = DshBeam.Runtime.reconcile(socket.assigns.runtime, specs ++ @demo_entries)
    {:noreply, refresh(socket)}
  end

  def handle_event("ask", %{"text" => text}, socket) do
    case loop_pid(socket.assigns.runtime) do
      {:ok, loop} ->
        # Run the whole model↔tool loop off the LiveView process: the loop
        # makes a real (up to 2-minute) HTTP call, which must not block the
        # event handler and freeze the chat pane. The result is pushed back
        # as a message and rendered in handle_info/2.
        from = self()

        Task.start(fn ->
          result = DshBeam.Agent.Loop.run_trace(loop, text)
          send(from, {:chat_result, text, result})
        end)

        {:noreply, socket |> assign(chat_text: "", chat_busy: true) |> refresh()}

      :not_found ->
        {:noreply,
         socket
         |> assign(
           chat_log: socket.assigns.chat_log ++ [{"user", text}, {"error", ":no_loop_plugin"}],
           chat_text: ""
         )
         |> refresh()}
    end
  end

  def handle_event("llm_apply", params, socket) do
    result =
      case DshBeam.Context.get(socket.assigns.ctx, :llm) do
        {:ok, llm} ->
          opts = [base_url: params["base_url"], model: params["model"]]

          # a blank credential field keeps the current key (the harness's
          # "leave blank to keep the current key")
          opts =
            case {params["credential_mode"], params["credential_value"]} do
              {_mode, ""} -> opts
              {"literal", value} -> Keyword.put(opts, :credential, {:literal, value})
              {_mode, value} -> Keyword.put(opts, :credential, {:env, value})
            end

          DshBeam.Llm.configure(llm, opts)

        :not_found ->
          {:error, :no_llm_plugin}
      end

    {:noreply, socket |> assign(llm_result: inspect(result)) |> refresh()}
  end

  def handle_event("settings_save", params, socket) do
    plugin = String.to_existing_atom(params["plugin"])
    store = DshBeam.Runtime.settings(socket.assigns.runtime)
    values = params["settings"] || %{}

    DshBeam.Plugin.settings(plugin)
    |> Enum.each(fn setting ->
      raw = values[to_string(setting.name)]

      if raw != nil do
        case parse_setting(setting, raw) do
          {:ok, value} -> DshBeam.Settings.put(store, plugin, setting.name, value)
          :skip -> :ok
          :invalid -> :ok
        end
      end
    end)

    {:noreply, refresh(socket)}
  end

  defp parse_setting(%{type: :integer}, raw) do
    case Integer.parse(raw) do
      {value, ""} -> {:ok, value}
      _ -> :invalid
    end
  end

  defp parse_setting(%{type: :float}, raw) do
    case Float.parse(raw) do
      {value, ""} -> {:ok, value}
      _ -> :invalid
    end
  end

  defp parse_setting(%{type: :boolean}, raw) do
    case raw do
      "true" -> {:ok, true}
      "false" -> {:ok, false}
      _ -> :invalid
    end
  end

  defp parse_setting(%{type: :string}, raw), do: {:ok, raw}

  defp parse_setting(%{type: :atom}, raw) do
    try do
      {:ok, String.to_existing_atom(raw)}
    rescue
      _ -> :invalid
    end
  end

  defp parse_setting(%{type: :credential}, ""), do: :skip

  defp parse_setting(%{type: :credential}, raw) do
    case String.split(raw, ":", parts: 2) do
      ["env", name] -> {:ok, {:env, name}}
      ["literal", key] -> {:ok, {:literal, key}}
      _ -> :invalid
    end
  end

  defp parse_setting(_setting, _raw), do: :invalid

  @impl true
  def handle_info({:chat_result, text, result}, socket) do
    turn =
      case result do
        {:ok, answer, trace} ->
          [{"user", text} | Enum.map(trace, &trace_entry/1)] ++ [{"assistant", answer}]

        {:error, reason} ->
          [{"user", text}, {"error", inspect(reason)}]
      end

    {:noreply,
     socket
     |> assign(chat_log: socket.assigns.chat_log ++ turn, chat_busy: false)
     |> refresh()}
  end

  def handle_info({:dsh_event, event}, socket) do
    {:noreply,
     socket |> assign(:events, Enum.take([event | socket.assigns.events], 100)) |> refresh()}
  end

  def handle_info({:dsh_runtime_event, _event}, socket) do
    {:noreply, refresh(socket)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main>
      <section>
        <h2>composition</h2>
        <form class="row" phx-submit="seed">
          <button type="submit">seed demo (session + llm + chat)</button>
        </form>
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
        <p class="muted">kill = external kill (recorded, not re-injected). crash child = sandbox SIGKILL (guard + re-injection).</p>
      </section>

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

      <section>
        <h2>chat</h2>
        <div class="chat">
          <ul>
            <%= for {role, content} <- @chat_log do %>
              <li><strong><%= role %></strong>: <code><%= content %></code></li>
            <% end %>
            <%= if @chat_busy do %>
              <li><strong>…</strong>: <code>thinking (model round-trip)</code></li>
            <% end %>
          </ul>
        </div>
        <form class="row" phx-submit="ask">
          <input type="text" name="text" value={@chat_text} placeholder="run a task (drives the agent loop)" style="flex:1" disabled={@chat_busy} />
          <button type="submit" disabled={@chat_busy}>ask</button>
        </form>
      </section>

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

      <section>
        <h2>creator / sandbox</h2>
        <form phx-submit="define">
          <select name="mode">
            <option value="trusted" selected={@mode == "trusted"}>trusted (Creator, in-process)</option>
            <option value="sandbox" selected={@mode == "sandbox"}>sandbox (child OS process)</option>
          </select>
          <textarea name="source"><%= @source %></textarea>
          <button type="submit">define</button>
        </form>
        <p class="muted">result: <code><%= inspect(@result) %></code></p>
      </section>

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

      <section>
        <h2>plugins</h2>
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
      </section>
    </main>
    """
  end

  # -- internals --

  defp loop_pid(runtime) do
    case DshBeam.Runtime.entries(runtime) do
      %{loop: %{pid: pid}} when is_pid(pid) -> {:ok, pid}
      _ -> :not_found
    end
  end

  defp trace_entry({:tool_call, name, args}), do: {"tool_call", "#{name} #{inspect(args)}"}
  defp trace_entry({:tool_result, name, result}), do: {"tool_result", "#{name} -> #{result}"}

  defp refs(session) do
    case session do
      %{"runtime" => runtime, "ctx" => ctx} ->
        %{runtime: decode_pid(runtime), ctx: decode_pid(ctx)}

      _ ->
        :persistent_term.get({DshBeam.Console, :refs}, nil) ||
          raise "no console refs: start DshBeam.Console or pass session params"
    end
  end

  defp decode_pid(encoded), do: encoded |> Base.decode64!() |> :erlang.binary_to_term()

  defp refresh(socket) do
    runtime = socket.assigns.runtime
    entries = DshBeam.Runtime.entries(runtime)
    %{bindings: bindings, fibers: fibers} = DshBeam.Context.snapshot(socket.assigns.ctx)

    rows =
      Enum.map(entries, fn {id, rec} ->
        fiber = Map.get(fibers, rec.pid)

        %{
          id: id,
          id_key: encode_id(id),
          plugin: rec.spec.plugin |> inspect() |> String.replace("Elixir.", ""),
          pid: rec.pid,
          state: if(fiber, do: fiber.state, else: :gone),
          restarts: rec.restarts,
          error: rec.error,
          os_pid: os_pid_for(rec),
          sandboxed: rec.spec.plugin == DshBeam.Sandbox.Plugin
        }
      end)

    llm_config =
      case DshBeam.Context.get(socket.assigns.ctx, :llm) do
        {:ok, llm} when is_pid(llm) -> DshBeam.Llm.config(llm)
        _ -> nil
      end

    {credential_mode, credential_env} =
      case llm_config && llm_config.credential do
        {:literal, _} -> {"literal", ""}
        {:env, name} -> {"env", name}
        _ -> {"env", "DEEPSEEK_API_KEY"}
      end

    assign(socket,
      rows: rows,
      bindings: bindings,
      llm_config: llm_config,
      credential_mode: credential_mode,
      credential_env: credential_env,
      inventory: build_inventory(runtime, entries)
    )
  end

  defp build_inventory(runtime, entries) do
    store = DshBeam.Runtime.settings(runtime)
    mounted = MapSet.new(entries, fn {_id, rec} -> rec.spec.plugin end)

    DshBeam.Plugin.Inventory.installed()
    |> Enum.map(fn entry ->
      %{
        plugin: entry.plugin,
        name: entry.plugin |> inspect() |> String.replace("Elixir.", ""),
        enabled: MapSet.member?(mounted, entry.plugin),
        settings: Enum.map(entry.settings, &setting_view(store, entry.plugin, &1))
      }
    end)
  end

  defp setting_view(store, plugin, setting) do
    value =
      case DshBeam.Settings.get(store, plugin, setting.name) do
        {:ok, value} -> value
        _ -> setting.default
      end

    %{
      name: setting.name,
      type: setting.type,
      doc: setting.doc,
      value: value,
      display: setting_display(setting.type, value)
    }
  end

  defp setting_display(:credential, {:env, name}), do: "env:" <> name
  defp setting_display(:credential, {:literal, _key}), do: "literal:"
  defp setting_display(_type, value), do: to_string(value)

  defp os_pid_for(%{plugin: DshBeam.Sandbox.Plugin, pid: pid}) when is_pid(pid) do
    # the adapter may be mid-crash when the event refresh runs: never let a
    # call to a dying fiber take the console down
    if Process.alive?(pid) do
      try do
        DshBeam.Sandbox.Plugin.os_pid(pid)
      catch
        :exit, _ -> nil
      end
    end
  end

  defp os_pid_for(_rec), do: nil

  defp current_specs(runtime) do
    runtime
    |> DshBeam.Runtime.entries()
    |> Enum.map(fn {_id, %{spec: entry}} -> entry end)
  end

  defp reject_spec(runtime, id) do
    runtime |> current_specs() |> Enum.reject(&(&1.id == id))
  end

  defp encode_id(id), do: id |> :erlang.term_to_binary() |> Base.encode64()

  # :safe prevents atom creation from hostile payloads; membership against
  # the live entry map double-checks the id actually exists.
  defp decode_id!(runtime, id_key) do
    id = id_key |> Base.decode64!() |> :erlang.binary_to_term([:safe])

    unless Map.has_key?(DshBeam.Runtime.entries(runtime), id) do
      raise "unknown entry id"
    end

    id
  end
end
