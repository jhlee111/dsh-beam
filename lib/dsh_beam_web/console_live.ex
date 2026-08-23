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
    %{id: :todo, plugin: DshBeam.Tool.Todo, config: [], disabled: false},
    %{id: :loop, plugin: DshBeam.Agent.Loop, config: [], disabled: false},
    %{id: :panel_composition, plugin: DshBeam.Ui.Panel.Composition, config: [], disabled: false},
    %{id: :panel_bindings, plugin: DshBeam.Ui.Panel.Bindings, config: [], disabled: false},
    %{id: :panel_chat, plugin: DshBeam.Ui.Panel.Chat, config: [], disabled: false},
    %{id: :panel_todo, plugin: DshBeam.Ui.Panel.Todo, config: [], disabled: false},
    %{id: :panel_llm, plugin: DshBeam.Ui.Panel.LlmSettings, config: [], disabled: false},
    %{id: :panel_creator, plugin: DshBeam.Ui.Panel.Creator, config: [], disabled: false},
    %{id: :panel_events, plugin: DshBeam.Ui.Panel.EventFeed, config: [], disabled: false},
    %{id: :panel_plugins, plugin: DshBeam.Ui.Panel.Plugins, config: [], disabled: false}
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
      |> assign(:chat_error, nil)
      |> assign(:todos, [])
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

  def handle_event("export_plugin", _params, socket) do
    # Export the live composition (including any creator-defined plugin source
    # in the editor) as a deployable .exs plugin file under the workspace.
    dir = Path.join(File.cwd!(), "plugins")
    File.mkdir_p!(dir)
    path = Path.join(dir, "composition.exs")

    sources =
      case module_name(socket.assigns.source) do
        {:ok, _mod} -> %{source: socket.assigns.source}
        _ -> %{}
      end

    result = DshBeam.Creator.export_plugin(socket.assigns.runtime, path, sources)

    {:noreply, socket |> assign(result: inspect(result)) |> refresh()}
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
      |> Enum.reject(
        &(&1.id in [
            :session,
            :llm,
            :shell,
            :bash,
            :fs,
            :todo,
            :loop,
            :panel_composition,
            :panel_bindings,
            :panel_chat,
            :panel_todo,
            :panel_llm,
            :panel_creator,
            :panel_events,
            :panel_plugins
          ])
      )

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
         |> assign(chat_text: "", chat_error: ":no_loop_plugin")
         |> refresh()}
    end
  end

  def handle_event("clear_chat", _params, socket) do
    case DshBeam.Context.get(socket.assigns.ctx, :session) do
      {:ok, session} when is_pid(session) -> DshBeam.Session.clear(session)
      _ -> :ok
    end

    {:noreply, socket |> assign(chat_error: nil) |> refresh()}
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

    # Re-mount the plugin so the resolved (now-overridden) settings reach its
    # live config — a saved :max_steps takes effect immediately.
    case entry_id_for_plugin(socket.assigns.runtime, plugin) do
      nil -> :ok
      id -> DshBeam.Runtime.restart(socket.assigns.runtime, id)
    end

    {:noreply, refresh(socket)}
  end

  defp entry_id_for_plugin(runtime, plugin) do
    runtime
    |> DshBeam.Runtime.entries()
    |> Enum.find_value(fn {id, rec} -> if rec.spec.plugin == plugin, do: id end)
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
  def handle_info({:chat_result, _text, result}, socket) do
    # The loop already wrote every step (user → tool_call → tool_result →
    # assistant, or error) to the session, so re-reading it renders the turn.
    # Only a hard failure (the loop fiber died mid-call) surfaces here.
    socket =
      case result do
        {:ok, _answer, _trace} -> assign(socket, chat_busy: false)
        {:error, reason} -> assign(socket, chat_busy: false, chat_error: inspect(reason))
      end

    {:noreply, refresh(socket)}
  end

  def handle_info({:dsh_event, event}, socket) do
    {:noreply,
     socket |> assign(:events, Enum.take([event | socket.assigns.events], 100)) |> refresh()}
  end

  def handle_info({:dsh_session_event, _event}, socket) do
    {:noreply, refresh(socket)}
  end

  def handle_info({:dsh_runtime_event, _event}, socket) do
    {:noreply, refresh(socket)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main>
      <%= DshBeam.Ui.render_slot(:panels, assigns) %>
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
      chat_log: chat_log(socket.assigns.ctx),
      todos: todos(socket.assigns.ctx),
      inventory: build_inventory(runtime, entries)
    )
  end

  # The todo list is a projection of the session: the latest todo_write event
  # (whole-list, last-write-wins), nil before the first write.
  defp todos(ctx) do
    case DshBeam.Context.get(ctx, :session) do
      {:ok, session} when is_pid(session) ->
        session
        |> DshBeam.Session.all()
        |> Enum.filter(&(&1["role"] == "todo_write"))
        |> List.last()
        |> case do
          nil -> []
          %{"todos" => todos} when is_list(todos) -> todos
          _ -> []
        end

      _ ->
        []
    end
  end

  # The chat pane renders the session log (the single source of truth), so the
  # conversation survives a page refresh and tool calls appear chronologically.
  defp chat_log(ctx) do
    case DshBeam.Context.get(ctx, :session) do
      {:ok, session} when is_pid(session) ->
        # idempotent: once subscribed, appends fan out {:dsh_session_event, ...}
        # and re-render the pane incrementally (reactive coeffect, not polling)
        _ = DshBeam.Session.subscribe(session)

        session
        |> DshBeam.Session.all()
        |> Enum.map(&chat_entry/1)

      _ ->
        []
    end
  end

  defp chat_entry(%{"role" => "user", "content" => content}), do: {"user", content}
  defp chat_entry(%{"role" => "assistant", "content" => content}), do: {"assistant", content}

  defp chat_entry(%{"role" => "tool_call", "name" => name, "arguments" => args}),
    do: {"tool_call", "#{name} #{inspect(args)}"}

  defp chat_entry(%{"role" => "tool_result", "name" => name, "content" => content}),
    do: {"tool_result", "#{name} -> #{content}"}

  defp chat_entry(%{"role" => "error", "content" => content}), do: {"error", content}
  defp chat_entry(other), do: {"event", inspect(other)}

  defp module_name(source) do
    case Regex.run(~r/^\s*defmodule\s+([A-Z]\w*)/, source) do
      [_, name] -> {:ok, name}
      _ -> :none
    end
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
