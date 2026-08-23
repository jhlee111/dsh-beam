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
    %{id: :workspace, plugin: DshBeam.Workspace, config: [], disabled: false},
    %{id: :llm, plugin: DshBeam.Llm.Plugin, config: [], disabled: false},
    %{id: :adapter, plugin: DshBeam.Llm.Adapter.Req, config: [], disabled: false},
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
    %{id: :panel_plugins, plugin: DshBeam.Ui.Panel.Plugins, config: [], disabled: false},
    %{id: :panel_workspace, plugin: DshBeam.Ui.Panel.Workspace, config: [], disabled: false},
    %{id: :panel_trajectory, plugin: DshBeam.Ui.Panel.Trajectory, config: [], disabled: false}
  ]

  # The entries a seed/preset-apply swaps out of a composition: the agent core
  # plus the fixed UI panels. Everything else (the console itself, creator-made
  # plugins) is preserved.
  @reseed_ids [
    :session,
    :workspace,
    :llm,
    :adapter,
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
    :panel_plugins,
    :panel_workspace,
    :panel_trajectory
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
      |> assign(:workspace_sessions, [])
      |> assign(:workspace_repo, ".")
      |> assign(:workspace_result, nil)
      |> assign(:trajectory, [])
      |> assign(:settings_open, false)
      |> assign(:settings_section, :models)
      |> assign(:view_tab, :chat)
      |> assign(:plugin_open, MapSet.new())
      |> assign(:plugin_drafts, %{})
      |> assign(:plugins_result, nil)
      |> assign(:custom_presets, [])
      |> assign(:presets_result, nil)
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
            :workspace,
            :llm,
            :adapter,
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
            :panel_plugins,
            :panel_workspace,
            :panel_trajectory
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

  def handle_event("workspace_create", %{"repo" => repo} = params, socket) do
    result =
      with {:ok, workspace} <- workspace_pid(socket.assigns.ctx),
           repo when is_binary(repo) and repo != "" <- repo do
        title =
          case params["title"] do
            "" -> nil
            nil -> nil
            t -> t
          end

        opts = if title, do: [title: title], else: []
        DshBeam.Workspace.open_session(workspace, repo, opts)
      else
        :not_found -> {:error, :no_workspace_plugin}
        _ -> {:error, :empty_repo}
      end

    {:noreply, socket |> assign(workspace_result: result) |> refresh()}
  end

  def handle_event("workspace_switch", %{"session" => session_key}, socket) do
    session = session_key |> Base.decode64!() |> :erlang.binary_to_term([:safe])
    :ok = switch_session(socket.assigns.runtime, session)
    {:noreply, refresh(socket)}
  end

  def handle_event("workspace_close", %{"session" => session_key}, socket) do
    session = session_key |> Base.decode64!() |> :erlang.binary_to_term([:safe])

    result =
      with {:ok, workspace} <- workspace_pid(socket.assigns.ctx) do
        DshBeam.Workspace.close_session(workspace, session)
      end

    {:noreply, socket |> assign(workspace_result: result) |> refresh()}
  end

  def handle_event("llm_apply", params, socket) do
    # The Models surface. A blank credential field keeps the current key (as
    # before). Model/base_url/credential are also persisted to the settings
    # store so they survive a restart. The running provider is re-armed
    # in-memory via configure/2 (dynamic reconfiguration — no re-mount), while
    # the store carries the value to the next boot.
    base_url = params["base_url"] || "https://api.deepseek.com"
    model = params["model"] || "deepseek-chat"

    credential =
      case {params["credential_mode"], params["credential_value"]} do
        {_mode, ""} -> nil
        {"literal", value} -> {:literal, value}
        {_mode, value} -> {:env, value}
      end

    result =
      case DshBeam.Context.get(socket.assigns.ctx, :llm) do
        {:ok, llm} ->
          opts = [base_url: base_url, model: model]
          opts = if credential, do: Keyword.put(opts, :credential, credential), else: opts
          configure_result = DshBeam.Llm.configure(llm, opts)
          persisted = persist_llm(socket.assigns.runtime, base_url, model, credential)

          case {configure_result, persisted} do
            {:ok, true} -> {:ok, "saved + persisted (next boot applies the stored config)"}
            {:ok, false} -> {:error, :persist_failed}
            other -> other
          end

        :not_found ->
          {:error, :no_llm_plugin}
      end

    {:noreply, socket |> assign(llm_result: inspect(result)) |> refresh()}
  end

  def handle_event("settings_save", params, socket) do
    plugin = decode_plugin!(params["plugin"])
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

    {:noreply,
     socket
     |> assign(plugin_drafts: Map.delete(socket.assigns.plugin_drafts, plugin))
     |> assign(plugins_result: "saved #{friendly_plugin_name(plugin)}")
     |> refresh()}
  end

  def handle_event("open_settings", _params, socket) do
    {:noreply, socket |> assign(settings_open: true, settings_section: :models) |> refresh()}
  end

  def handle_event("close_settings", _params, socket) do
    {:noreply, assign(socket, settings_open: false) |> refresh()}
  end

  def handle_event("view_tab", %{"tab" => tab}, socket) do
    view_tab = if tab == "trajectory", do: :trajectory, else: :chat
    {:noreply, assign(socket, view_tab: view_tab) |> refresh()}
  end

  def handle_event("plugin_toggle", %{"plugin" => plugin_str}, socket) do
    plugin = decode_plugin!(plugin_str)
    open = socket.assigns.plugin_open

    open =
      if MapSet.member?(open, plugin),
        do: MapSet.delete(open, plugin),
        else: MapSet.put(open, plugin)

    {:noreply, assign(socket, plugin_open: open) |> refresh()}
  end

  def handle_event("plugin_edit", %{"plugin" => plugin_str, "settings" => settings}, socket) do
    plugin = decode_plugin!(plugin_str)
    drafts = Map.put(socket.assigns.plugin_drafts, plugin, settings)
    {:noreply, assign(socket, plugin_drafts: drafts) |> refresh()}
  end

  def handle_event("plugin_discard", %{"plugin" => plugin_str}, socket) do
    plugin = decode_plugin!(plugin_str)
    drafts = Map.delete(socket.assigns.plugin_drafts, plugin)
    {:noreply, assign(socket, plugin_drafts: drafts) |> refresh()}
  end

  def handle_event("preset_default", %{"preset" => id}, socket) do
    store = DshBeam.Runtime.settings(socket.assigns.runtime)
    :ok = DshBeam.Settings.put(store, DshBeam.Ui.Panel.General, :default_preset, id)
    {:noreply, socket |> assign(presets_result: "default = #{id}") |> refresh()}
  end

  def handle_event("preset_apply", %{"preset" => id}, socket) do
    entries = preset_entries_for(id, socket.assigns.custom_presets)
    specs = socket.assigns.runtime |> current_specs() |> Enum.reject(&(&1.id in @reseed_ids))

    result = DshBeam.Runtime.reconcile(socket.assigns.runtime, specs ++ entries)

    {:noreply,
     socket |> assign(presets_result: "applied #{id} · #{inspect(result)}") |> refresh()}
  end

  def handle_event("preset_copy", %{"preset" => id, "name" => name}, socket) do
    name = name |> to_string() |> String.trim()
    new_id = if name == "", do: id <> "-copy", else: name
    entries = preset_entries_for(id, socket.assigns.custom_presets)

    custom =
      socket.assigns.custom_presets ++
        [%{id: new_id, name: name, desc: "copy of #{id}", entries: entries}]

    {:noreply, assign(socket, custom_presets: custom) |> refresh()}
  end

  def handle_event("preset_delete", %{"preset" => id}, socket) do
    custom = Enum.reject(socket.assigns.custom_presets, &(&1.id == id))
    {:noreply, assign(socket, custom_presets: custom) |> refresh()}
  end

  def handle_event("settings_tab", %{"section" => section_key}, socket) do
    section = String.to_existing_atom(section_key)
    {:noreply, assign(socket, settings_section: section) |> refresh()}
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
    <div
      class="frame"
      style="grid-template-columns: 280px minmax(0, 1fr) 280px"
    >
      <div class="frame-sidebar">
        <div class="sidebar-root">
          <div class="logo-row">
            <button class="brand" phx-click="open_settings">dsh-beam</button>
            <button class="toggle" phx-click="open_settings">panel</button>
          </div>
          <div class="region">
            <%= DshBeam.Ui.render_slot(:sidebar, assigns) %>
          </div>
          <div class="foot">
            <button class="settings-trigger" phx-click="open_settings">settings</button>
          </div>
        </div>
      </div>

      <div class="frame-center">
        <div class="conv-root" data-phase="active">
          <div class="conv-header">
            <div class="title-row">
              <div class="crumbs"><span class="crumb crumb-current">console</span></div>
            </div>
            <div class="tabs">
              <button
                class={"tab #{if @view_tab == :chat, do: "tab-active"}"}
                phx-click="view_tab"
                phx-value-tab="chat"
              >
                Chat
              </button>
              <button
                class={"tab #{if @view_tab == :trajectory, do: "tab-active"}"}
                phx-click="view_tab"
                phx-value-tab="trajectory"
              >
                Trajectory
              </button>
            </div>
          </div>
          <div class="conv-scroll">
            <%= DshBeam.Ui.render_slot(:conversation, assigns, key: @view_tab) %>
            <div class="composer-seat">
              <form class="composer" phx-submit="ask">
                <input
                  type="text"
                  name="text"
                  value={@chat_text}
                  placeholder="run a task (drives the agent loop)"
                  disabled={@chat_busy}
                />
                <button type="submit" disabled={@chat_busy}>ask</button>
                <button type="button" phx-click="clear_chat">new conversation</button>
              </form>
              <%= if @chat_busy do %>
                <div class="composer-status muted">thinking (model round-trip)…</div>
              <% end %>
            </div>
          </div>
        </div>
      </div>

      <div class="frame-details">
        <%= DshBeam.Ui.render_slot(:details, assigns) %>
      </div>
    </div>

    <%= if @settings_open do %>
      <div class="settings-overlay" phx-click="close_settings">
        <div class="settings-panel" phx-click-stop>
          <nav class="settings-nav">
            <%= for section <- @settings_sections do %>
              <button
                phx-click="settings_tab"
                phx-value-section={section.key}
                class={"settings-nav-item #{if section.key == @settings_section, do: "active"}"}
              >
                <%= section.label %>
              </button>
            <% end %>
            <button phx-click="close_settings" class="settings-nav-item close">close</button>
          </nav>
          <div class="settings-content">
            <%= DshBeam.Ui.render_slot(:settings_section, assigns, key: @settings_section) %>
          </div>
        </div>
      </div>
    <% end %>
    """
  end

  # -- internals --

  # Re-point the :session binding at a workspace session by reconfiguring the
  # session entry and reconciling — the provider-swap path of the substrate
  # (the guard deactivates dependents first, then the new session mounts).
  defp switch_session(runtime, session) do
    specs =
      runtime
      |> current_specs()
      |> Enum.map(fn entry ->
        if entry.id == :session, do: %{entry | config: [session: session]}, else: entry
      end)

    DshBeam.Runtime.reconcile(runtime, specs)
  end

  defp workspace_pid(ctx) do
    case DshBeam.Context.get(ctx, :workspace) do
      {:ok, workspace} when is_pid(workspace) -> {:ok, workspace}
      _ -> :not_found
    end
  end

  defp persist_llm(runtime, base_url, model, credential) do
    store = DshBeam.Runtime.settings(runtime)

    :ok == DshBeam.Settings.put(store, DshBeam.Llm.Plugin, :base_url, base_url) and
      :ok == DshBeam.Settings.put(store, DshBeam.Llm.Plugin, :model, model) and
      (is_nil(credential) or
         :ok == DshBeam.Settings.put(store, DshBeam.Llm.Plugin, :credential, credential))
  end

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

    store = DshBeam.Runtime.settings(runtime)
    default_preset = resolve_default_preset(store)

    assign(socket,
      rows: rows,
      bindings: bindings,
      llm_config: llm_config,
      credential_mode: credential_mode,
      credential_env: credential_env,
      chat_log: chat_log(socket.assigns.ctx),
      todos: todos(socket.assigns.ctx),
      trajectory: trajectory(socket.assigns.ctx),
      workspace_sessions: workspace_sessions(socket.assigns.ctx),
      inventory:
        build_inventory(
          runtime,
          entries,
          socket.assigns.plugin_open,
          socket.assigns.plugin_drafts
        ),
      presets: roster(socket.assigns.custom_presets, default_preset),
      default_preset: default_preset,
      workspace_default_root: resolve_workspace_root(store),
      settings_sections: settings_sections()
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

  # The trajectory is the same session log grouped by turn: a "user" event opens
  # a turn; the tool calls, results, and the answer that follow belong to it.
  defp trajectory(ctx) do
    case DshBeam.Context.get(ctx, :session) do
      {:ok, session} when is_pid(session) ->
        session
        |> DshBeam.Session.all()
        |> group_turns()
        |> Enum.map(fn turn -> Enum.map(turn, &chat_entry/1) end)

      _ ->
        []
    end
  end

  defp group_turns(events) do
    {turns, current} =
      Enum.reduce(events, {[], []}, fn event, {turns, current} ->
        if event["role"] == "user" do
          {[Enum.reverse(current) | turns], [event]}
        else
          {turns, [event | current]}
        end
      end)

    (turns ++ [Enum.reverse(current)])
    |> Enum.reject(&(&1 == []))
    |> Enum.reverse()
  end

  # The workspace sidebar: every workspace session, with its current/current?
  # flag and an encoded key for the switch/close events.
  defp workspace_sessions(ctx) do
    with {:ok, workspace} when is_pid(workspace) <- DshBeam.Context.get(ctx, :workspace),
         sessions when is_map(sessions) <- safe_sessions(workspace) do
      current =
        case DshBeam.Context.get(ctx, :session) do
          {:ok, session} when is_pid(session) -> session
          _ -> nil
        end

      sessions
      |> Enum.map(fn {session, meta} ->
        %{
          session: session,
          session_key: encode_id(session),
          title: meta.title || inspect(session),
          cwd: meta.cwd,
          current: session == current
        }
      end)
      |> Enum.sort_by(& &1.title)
    else
      _ -> []
    end
  end

  defp safe_sessions(workspace) do
    if Process.alive?(workspace) do
      DshBeam.Workspace.all_sessions(workspace)
    else
      %{}
    end
  catch
    :exit, _ -> %{}
  end

  # The settings modal's left nav: every registered settings section, sorted by
  # order, with a human label (the ui_slot DSL has no label field, so sections
  # carry a `key` and the shell maps it here).
  defp settings_sections do
    labels = %{
      general: "General",
      presets: "Agent presets",
      models: "Models",
      plugins: "Plugins",
      composition: "Composition",
      bindings: "Bindings",
      events: "Events",
      creator: "Creator"
    }

    DshBeam.Ui.Registry.for_slot(:settings_section)
    |> Enum.sort_by(& &1.order)
    |> Enum.map(fn entry ->
      %{key: entry.key, label: Map.get(labels, entry.key, inspect(entry.key))}
    end)
  end

  # -- agent presets (reference ui-agent-preset) --

  defp panel_entries do
    Enum.filter(@demo_entries, &String.starts_with?(to_string(&1.id), "panel_"))
  end

  defp core_entries(ids) do
    Enum.filter(@demo_entries, &(&1.id in ids))
  end

  defp builtin_presets do
    [
      %{
        id: "demo",
        name: "Demo",
        desc: "Full console: session, workspace, llm, shell, tools, loop",
        entries: @demo_entries
      },
      %{
        id: "agent",
        name: "Agent",
        desc: "Session + llm + adapter + shell + bash + loop",
        entries: panel_entries() ++ core_entries([:session, :llm, :adapter, :shell, :bash, :loop])
      },
      %{
        id: "chat",
        name: "Chat",
        desc: "Session + llm + adapter + loop (no tools)",
        entries: panel_entries() ++ core_entries([:session, :llm, :adapter, :loop])
      }
    ]
  end

  defp roster(custom_presets, default_preset) do
    builtin = Enum.map(builtin_presets(), &Map.put(&1, :builtin, true))
    custom = Enum.map(custom_presets, &Map.put(&1, :builtin, false))

    (builtin ++ custom)
    |> Enum.map(&Map.put(&1, :default, &1.id == default_preset))
  end

  defp preset_entries_for(id, custom_presets) do
    case Enum.find(custom_presets, &(&1.id == id)) do
      nil ->
        Enum.find_value(builtin_presets(), fn p -> if p.id == id, do: p.entries end) || []

      preset ->
        preset.entries
    end
  end

  defp resolve_default_preset(store) do
    case DshBeam.Settings.get(store, DshBeam.Ui.Panel.General, :default_preset) do
      {:ok, value} -> to_string(value)
      _ -> "demo"
    end
  end

  defp resolve_workspace_root(store) do
    case DshBeam.Settings.get(store, DshBeam.Ui.Panel.General, :workspace_default_root) do
      {:ok, value} -> to_string(value)
      _ -> "."
    end
  end

  defp module_name(source) do
    case Regex.run(~r/^\s*defmodule\s+([A-Z]\w*)/, source) do
      [_, name] -> {:ok, name}
      _ -> :none
    end
  end

  defp build_inventory(runtime, entries, plugin_open, plugin_drafts) do
    store = DshBeam.Runtime.settings(runtime)
    mounted = MapSet.new(entries, fn {_id, rec} -> rec.spec.plugin end)

    DshBeam.Plugin.Inventory.installed()
    |> Enum.map(fn entry ->
      plugin = entry.plugin
      drafts = Map.get(plugin_drafts, plugin, %{})

      %{
        plugin: plugin,
        name: friendly_plugin_name(plugin),
        enabled: MapSet.member?(mounted, plugin),
        open: MapSet.member?(plugin_open, plugin),
        dirty: map_size(drafts) > 0,
        desc: plugin_desc(plugin),
        settings: Enum.map(entry.settings, &setting_view(store, plugin, &1, drafts))
      }
    end)
    |> Enum.sort_by(& &1.name)
  end

  defp setting_view(store, plugin, setting, drafts) do
    value =
      case DshBeam.Settings.get(store, plugin, setting.name) do
        {:ok, value} -> value
        _ -> setting.default
      end

    display = setting_display(setting.type, value)

    %{
      name: setting.name,
      type: setting.type,
      doc: setting.doc,
      value: value,
      display: display,
      text: Map.get(drafts, to_string(setting.name), display)
    }
  end

  defp setting_display(:credential, {:env, name}), do: "env:" <> name
  defp setting_display(:credential, {:literal, _key}), do: "literal:"
  defp setting_display(_type, value), do: to_string(value)

  # A short human label for the card header and save notice; falls back to the
  # module's own name when the plugin is not one of the known hosts.
  @plugin_names %{
    DshBeam.Shell.Plugin => "Shell",
    DshBeam.Agent.Loop => "Agent Loop",
    DshBeam.Tool.Bash => "Tool: Bash",
    DshBeam.Tool.Fs => "Tool: Files",
    DshBeam.Tool.Todo => "Tool: Todo",
    DshBeam.Workspace => "Workspace",
    DshBeam.Llm.Plugin => "LLM"
  }

  defp friendly_plugin_name(plugin) do
    Map.get_lazy(@plugin_names, plugin, fn ->
      plugin |> inspect() |> String.replace("Elixir.", "")
    end)
  end

  @plugin_descriptions %{
    DshBeam.Shell.Plugin => "Command timeout and output cap per stream",
    DshBeam.Agent.Loop => "Max model→tool round-trips",
    DshBeam.Tool.Todo => "The agent's plan/todo list",
    DshBeam.Workspace => "Default root for new session worktrees",
    DshBeam.Llm.Plugin => "Provider, model, and credential"
  }

  defp plugin_desc(plugin) do
    Map.get(@plugin_descriptions, plugin, "Configure this plugin's settings")
  end

  # Decode an inspect/1 or to_string/1 form of a module back to the module atom.
  # Both "DshBeam.Shell.Plugin" (inspect) and "Elixir.DshBeam.Shell.Plugin"
  # (to_string) reach the loaded module atom.
  defp decode_plugin!(str) do
    str = to_string(str)
    str = if String.starts_with?(str, "Elixir."), do: str, else: "Elixir." <> str
    String.to_existing_atom(str)
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
