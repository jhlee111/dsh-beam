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
    %{
      id: :llm,
      plugin: DshBeam.Llm.Plugin,
      config: [adapter: DshBeam.Llm.Adapter.Echo],
      disabled: false
    },
    %{id: :chat, plugin: DshBeam.Llm.Chat, config: [], disabled: false}
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
      |> assign(:events, [])
      |> assign(:rows, [])
      |> assign(:bindings, %{})
      |> assign(:llm_config, nil)
      |> assign(:llm_result, nil)
      |> assign(:credential_mode, "env")
      |> assign(:credential_env, "DEEPSEEK_API_KEY")
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
      |> Enum.reject(&(&1.id in [:session, :llm, :chat]))

    :ok = DshBeam.Runtime.reconcile(socket.assigns.runtime, specs ++ @demo_entries)
    {:noreply, refresh(socket)}
  end

  def handle_event("ask", %{"text" => text}, socket) do
    reply =
      case DshBeam.Context.get(socket.assigns.ctx, :chat) do
        {:ok, chat} -> DshBeam.Llm.Chat.ask(chat, text)
        :not_found -> {:error, :no_chat_plugin}
      end

    entry = {"user", text}

    assistant =
      case reply do
        {:ok, %{content: content}} -> {"assistant", content}
        {:error, reason} -> {"error", inspect(reason)}
      end

    {:noreply,
     socket
     |> assign(chat_log: [assistant, entry | socket.assigns.chat_log], chat_text: "")
     |> refresh()}
  end

  def handle_event("llm_apply", params, socket) do
    result =
      case DshBeam.Context.get(socket.assigns.ctx, :llm) do
        {:ok, llm} ->
          credential =
            case params["credential_mode"] do
              "literal" -> {:literal, params["credential_value"]}
              _ -> {:env, params["credential_value"]}
            end

          DshBeam.Llm.configure(llm,
            base_url: params["base_url"],
            model: params["model"],
            credential: credential
          )

        :not_found ->
          {:error, :no_llm_plugin}
      end

    {:noreply, socket |> assign(llm_result: inspect(result)) |> refresh()}
  end

  @impl true
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
          </ul>
        </div>
        <form class="row" phx-submit="ask">
          <input type="text" name="text" value={@chat_text} placeholder="say something (needs session + llm + chat)" style="flex:1" />
          <button type="submit">ask</button>
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
            <select name="credential_mode">
              <option value="env" selected={@credential_mode == "env"}>env</option>
              <option value="literal" selected={@credential_mode == "literal"}>literal</option>
            </select>
            <input
              type="text"
              name="credential_value"
              value={@credential_env}
              placeholder={if @credential_mode == "env", do: "env name", else: "literal key (not echoed)"}
            />
            <button type="submit">apply (configure, no re-mount)</button>
          </form>
          <p class="muted">result: <code><%= inspect(@llm_result) %></code></p>
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
    </main>
    """
  end

  # -- internals --

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
      credential_env: credential_env
    )
  end

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
