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

  # Ceiling for one chat turn, independent of the per-request Req budget
  # (receive_timeout, default 300s): if the loop fiber hangs OUTSIDE Req — a
  # blocked gen_statem call the transport timeout cannot see — the watchdog
  # clears the pane instead of leaving it busy forever.
  @chat_result_timeout_ms 600_000

  @demo_entries [
    %{id: :session, plugin: DshBeam.Session.Plugin, config: [], disabled: false},
    %{id: :workspace, plugin: DshBeam.Workspace, config: [], disabled: false},
    %{id: :llm, plugin: DshBeam.Llm.Plugin, config: [], disabled: false},
    %{id: :adapter, plugin: DshBeam.Llm.Adapter.Req, config: [], disabled: false},
    %{id: :shell, plugin: DshBeam.Shell.Plugin, config: [], disabled: false},
    %{id: :bash, plugin: DshBeam.Tool.Bash, config: [], disabled: false},
    %{id: :fs, plugin: DshBeam.Tool.Fs, config: [root: "."], disabled: false},
    %{id: :todo, plugin: DshBeam.Tool.Todo, config: [], disabled: false},
    %{id: :goal, plugin: DshBeam.Tool.Goal, config: [], disabled: false},
    %{id: :goal_driver, plugin: DshBeam.Goal.Driver, config: [], disabled: false},
    %{id: :tool_plugin, plugin: DshBeam.Tool.Plugin, config: [], disabled: false},
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
    %{id: :panel_trajectory, plugin: DshBeam.Ui.Panel.Trajectory, config: [], disabled: false},
    %{id: :panel_access, plugin: DshBeam.Ui.Panel.Access, config: [], disabled: false},
    %{id: :panel_model_select, plugin: DshBeam.Ui.Panel.ModelSelect, config: [], disabled: false},
    %{id: :panel_command, plugin: DshBeam.Ui.Panel.Command, config: [], disabled: false},
    %{id: :panel_element_select, plugin: DshBeam.Ui.Panel.ElementSelect, config: [], disabled: false}
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
    :goal,
    :goal_driver,
    :tool_plugin,
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
    :panel_trajectory,
    :panel_access,
    :panel_model_select,
    :panel_command,
    :panel_element_select
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
      |> assign(:open_rows, MapSet.new())
      |> assign(:chat_busy, false)
      |> assign(:chat_task, nil)
      |> assign(:chat_turn, nil)
      |> assign(:chat_token, nil)
      |> assign(:chat_started_at, nil)
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
      |> assign(:sidebar_collapsed, false)
      |> assign(:sidebar_width, 280)
      |> assign(:details_width, 280)
      |> assign(:picker_open, false)
      |> assign(:picker_path, nil)
      |> assign(:picker_entries, [])
      |> assign(:permission, %{current_value: "workspace-write", options: []})
      |> assign(:permission_open, false)
      |> assign(:permission_confirming, nil)
      |> assign(:permission_acknowledged, false)
      |> assign(:model_open, false)
      |> assign(:model_pane, :root)
      |> assign(:command_open, false)
      |> assign(:trajectory_query, "")
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
            :panel_trajectory,
            :panel_access,
            :panel_model_select,
            :panel_command,
            :panel_element_select
          ])
      )

    :ok = DshBeam.Runtime.reconcile(socket.assigns.runtime, specs ++ @demo_entries)
    {:noreply, refresh(socket)}
  end

  def handle_event("element_pick", params, socket) do
    marker = DshBeam.Ui.Panel.ElementSelect.marker(params)

    current = socket.assigns.chat_text
    draft =
      if current == "" do
        marker
      else
        current <> "\n\n" <> marker
      end

    {:noreply, assign(socket, chat_text: draft) |> refresh()}
  end

  def handle_event("ask", %{"text" => text}, socket) do
    case DshBeam.Command.parse(text) do
      {:command, name, args} ->
        run_command(socket, name, args)

      {:not_command, _} ->
        ask_agent(socket, text)
    end
  end

  def handle_event("stop_chat", _params, socket) do
    # Cooperative stop: cancel the token so the loop halts at its next step
    # boundary (and the adapter aborts the in-flight model call), then kill
    # the caller task so the pane unblocks immediately. The loop authors the
    # "stopped by user" session event itself, so the transcript stays a
    # single-writer append-only log.
    if is_pid(socket.assigns.chat_task), do: Process.exit(socket.assigns.chat_task, :kill)

    if socket.assigns.chat_token do
      DshBeam.Agent.Cancel.cancel(socket.assigns.chat_token)
    end

    {:noreply,
     socket
     |> assign(
       chat_busy: false,
       chat_task: nil,
       chat_turn: nil,
       chat_token: nil,
       chat_started_at: nil
     )
     |> refresh()}
  end

  def handle_event("clear_chat", _params, socket) do
    case DshBeam.Context.get(socket.assigns.ctx, :session) do
      {:ok, session} when is_pid(session) -> DshBeam.Session.clear(session)
      _ -> :ok
    end

    {:noreply, socket |> assign(chat_error: nil) |> refresh()}
  end

  def handle_event("toggle_row", %{"id" => id}, socket) do
    # The reader's expanded/collapsed state is server-owned (open_rows), so the
    # <details open> attribute survives every re-render — the anti-pattern was a
    # JS hook mutating the DOM open attribute without phx-update="ignore".
    open_rows =
      if MapSet.member?(socket.assigns.open_rows, id) do
        MapSet.delete(socket.assigns.open_rows, id)
      else
        MapSet.put(socket.assigns.open_rows, id)
      end

    {:noreply,
     socket
     |> assign(open_rows: open_rows)
     |> assign(:chat_log, chat_entries(socket.assigns.ctx, socket.assigns.chat_busy, open_rows))}
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

    receive_timeout =
      case params["receive_timeout"] do
        raw when is_binary(raw) and raw != "" ->
          case Integer.parse(raw) do
            {value, ""} when value > 0 -> value
            _ -> nil
          end

        _ ->
          nil
      end

    result =
      case DshBeam.Context.get(socket.assigns.ctx, :llm) do
        {:ok, llm} ->
          opts = [base_url: base_url, model: model]
          opts = if credential, do: Keyword.put(opts, :credential, credential), else: opts

          opts =
            if receive_timeout,
              do: Keyword.put(opts, :receive_timeout, receive_timeout),
              else: opts

          configure_result = DshBeam.Llm.configure(llm, opts)

          persisted =
            persist_llm(socket.assigns.runtime, base_url, model, credential, receive_timeout)

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

  def handle_event("toggle_sidebar", _params, socket) do
    {:noreply,
     assign(socket, sidebar_collapsed: not socket.assigns.sidebar_collapsed) |> refresh()}
  end

  def handle_event("resize_sidebar", %{"width" => width}, socket) do
    width = width |> to_string() |> String.to_integer() |> max(200) |> min(520)
    {:noreply, assign(socket, sidebar_width: width) |> refresh()}
  end

  def handle_event("resize_details", %{"width" => width}, socket) do
    width = width |> to_string() |> String.to_integer() |> max(200) |> min(560)
    {:noreply, assign(socket, details_width: width) |> refresh()}
  end

  def handle_event("browse_dir", _params, socket) do
    root = Path.expand(socket.assigns.workspace_repo || ".")

    {:noreply,
     socket
     |> assign(picker_open: true, picker_path: root, picker_entries: list_dirs(root))
     |> refresh()}
  end

  def handle_event("picker_nav", %{"path" => path}, socket) do
    {:noreply, socket |> assign(picker_path: path, picker_entries: list_dirs(path)) |> refresh()}
  end

  def handle_event("picker_select", _params, socket) do
    {:noreply,
     socket
     |> assign(workspace_repo: socket.assigns.picker_path, picker_open: false)
     |> refresh()}
  end

  def handle_event("picker_cancel", _params, socket) do
    {:noreply, assign(socket, picker_open: false) |> refresh()}
  end

  def handle_event("view_tab", %{"tab" => tab}, socket) do
    view_tab = if tab == "trajectory", do: :trajectory, else: :chat
    {:noreply, assign(socket, view_tab: view_tab) |> refresh()}
  end

  # -- permission preset ("Access" seat) --

  def handle_event("permission_toggle", _params, socket) do
    {:noreply, assign(socket, permission_open: not socket.assigns.permission_open) |> refresh()}
  end

  def handle_event("permission_select", %{"preset" => preset}, socket) do
    # Full access gates behind a risk confirmation; safe presets apply at once.
    socket =
      if preset == "danger-full-access" do
        assign(socket, permission_confirming: preset, permission_acknowledged: false)
      else
        apply_permission(socket, preset)
      end

    {:noreply, socket |> assign(permission_open: false) |> refresh()}
  end

  def handle_event("permission_ack", _params, socket) do
    {:noreply,
     assign(socket, permission_acknowledged: not socket.assigns.permission_acknowledged)
     |> refresh()}
  end

  def handle_event("permission_confirm", _params, socket) do
    socket =
      if socket.assigns.permission_acknowledged && socket.assigns.permission_confirming do
        apply_permission(socket, socket.assigns.permission_confirming)
      else
        socket
      end

    {:noreply,
     socket
     |> assign(permission_confirming: nil, permission_acknowledged: false, permission_open: false)
     |> refresh()}
  end

  def handle_event("permission_cancel", _params, socket) do
    {:noreply,
     socket
     |> assign(permission_confirming: nil, permission_acknowledged: false, permission_open: false)
     |> refresh()}
  end

  # -- model / effort selector (the composer's model seat) --

  def handle_event("model_toggle", _params, socket) do
    socket =
      socket
      |> assign(model_open: not socket.assigns.model_open)
      |> assign(model_pane: :root)

    {:noreply, refresh(socket)}
  end

  def handle_event("model_pane", %{"pane" => pane}, socket) do
    # Literal atoms (not String.to_existing_atom) so both :model and :effort
    # exist regardless of load order.
    model_pane =
      case pane do
        "model" -> :model
        "effort" -> :effort
        _ -> :root
      end

    {:noreply, socket |> assign(model_pane: model_pane) |> refresh()}
  end

  def handle_event("model_select", %{"model" => model}, socket) do
    socket = apply_model(socket, model: model)
    {:noreply, socket |> assign(model_open: false, model_pane: :root) |> refresh()}
  end

  def handle_event("model_effort_select", %{"effort" => effort}, socket) do
    socket = apply_model(socket, reasoning_effort: effort)
    {:noreply, socket |> assign(model_open: false, model_pane: :root) |> refresh()}
  end

  # -- slash-command menu --

  def handle_event("command_toggle", _params, socket) do
    {:noreply, assign(socket, command_open: not socket.assigns.command_open) |> refresh()}
  end

  def handle_event("command_pick", %{"command" => name}, socket) do
    # Pick inserts the "/name " claim token into the draft; the user completes
    # the args and submits, which the ask handler routes through run_command.
    {:noreply,
     socket
     |> assign(chat_text: "/" <> name <> " ", command_open: false)
     |> refresh()}
  end

  def handle_event("trajectory_search", %{"query" => query}, socket) do
    {:noreply, socket |> assign(trajectory_query: query) |> refresh()}
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

  # Enable/disable a plugin entry: flip its disabled flag and reconcile, so a
  # disabled plugin stays in the desired composition (visible, re-enableable)
  # while its fiber is stopped. The console host itself cannot be disabled.
  def handle_event("plugin_enable", %{"plugin" => plugin_str, "enabled" => enabled_str}, socket) do
    plugin = decode_plugin!(plugin_str)

    if plugin == DshBeam.Console do
      {:noreply, refresh(socket)}
    else
      enable = enabled_str in ["true", "1"]
      runtime = socket.assigns.runtime
      current = current_specs(runtime)

      specs =
        case Enum.find(current, &(&1.plugin == plugin)) do
          nil ->
            # an inventoried plugin outside this composition: mount it as a
            # fresh entry (id = plugin module, the Creator's convention)
            current ++ [%{id: plugin, plugin: plugin, config: [], disabled: not enable}]

          %{id: id} ->
            Enum.map(current, fn
              %{id: ^id} = spec -> %{spec | disabled: not enable}
              spec -> spec
            end)
        end

      :ok = DshBeam.Runtime.reconcile(runtime, specs)

      {:noreply,
       socket
       |> assign(
         plugins_result:
           "#{if enable, do: "enabled", else: "disabled"} #{friendly_plugin_name(plugin)}"
       )
       |> refresh()}
    end
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
  def handle_info({:chat_result, turn, _text, result}, socket) do
    # Turn-scoped: ignore a result for a turn that already settled (the user
    # stopped it, or the watchdog fired) so it can never clobber a newer ask.
    socket =
      if socket.assigns.chat_turn == turn do
        case result do
          {:ok, _answer, _trace} ->
            assign(socket,
              chat_busy: false,
              chat_task: nil,
              chat_turn: nil,
              chat_token: nil,
              chat_started_at: nil
            )

          {:error, reason} ->
            assign(socket,
              chat_busy: false,
              chat_task: nil,
              chat_turn: nil,
              chat_token: nil,
              chat_started_at: nil,
              chat_error: inspect(reason)
            )
        end
      else
        socket
      end

    {:noreply, refresh(socket)}
  end

  # Watchdog: the loop fiber hung (blocked outside the Req transport budget)
  # — kill the task and settle the pane with a visible timeout error instead
  # of leaving chat_busy true forever.
  def handle_info({:chat_guard, turn}, socket) do
    if socket.assigns.chat_turn == turn do
      if is_pid(socket.assigns.chat_task), do: Process.exit(socket.assigns.chat_task, :kill)

      if socket.assigns.chat_token, do: DshBeam.Agent.Cancel.cancel(socket.assigns.chat_token)

      case DshBeam.Context.get(socket.assigns.ctx, :session) do
        {:ok, session} when is_pid(session) ->
          DshBeam.Session.append(session, %{
            "role" => "error",
            "content" => "chat timed out after #{@chat_result_timeout_ms}ms (loop task killed)"
          })

        _ ->
          :ok
      end

      {:noreply,
       socket
       |> assign(
         chat_busy: false,
         chat_task: nil,
         chat_turn: nil,
         chat_token: nil,
         chat_started_at: nil,
         chat_error: "timed out after #{@chat_result_timeout_ms}ms"
       )
       |> refresh()}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:dsh_event, event}, socket) do
    {:noreply,
     socket |> assign(:events, Enum.take([event | socket.assigns.events], 100)) |> refresh()}
  end

  def handle_info({:dsh_session_event, event}, socket) do
    # Streaming appends are the chat pane's hot path: update only the affected
    # stream item (append/new row or the growing reasoning tail) instead of the
    # full-console refresh, so word-sized deltas render without a full re-render.
    {:noreply, refresh_chat(socket, event)}
  end

  def handle_info({:dsh_runtime_event, _event}, socket) do
    {:noreply, refresh(socket)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      class="frame"
      data-dsh-region
      data-dsh-slot="layout"
      data-dsh-plugin="DshBeamWeb.ConsoleLive"
      data-dsh-source="lib/dsh_beam_web/console_live.ex"
      style={"grid-template-columns: " <> (if @sidebar_collapsed, do: "56px", else: "#{@sidebar_width}px") <> " minmax(0, 1fr) #{@details_width}px"}
    >
      <div class="frame-sidebar">
        <div class={"sidebar-root #{if @sidebar_collapsed, do: "collapsed"}"}>
          <div class="logo-row">
            <%= if @sidebar_collapsed do %>
              <button class="toggle" phx-click="toggle_sidebar" aria-label="expand sidebar">☰</button>
            <% else %>
              <span class="brand">dsh-beam</span>
              <button class="toggle" phx-click="toggle_sidebar" aria-label="collapse sidebar">☰</button>
            <% end %>
          </div>
          <%= unless @sidebar_collapsed do %>
            <div class="region">
              <%= for rendered <- DshBeam.Ui.render_slot(:sidebar, assigns) do %>
                <%= rendered %>
              <% end %>
            </div>
            <div class="foot">
              <button class="settings-trigger" phx-click="open_settings">settings</button>
            </div>
          <% end %>
        </div>
      </div>

      <%= unless @sidebar_collapsed do %>
        <div
          class="sidebar-handle"
          id="sidebar-handle"
          phx-hook="SidebarResize"
          style={"left: #{@sidebar_width - 4}px"}
        >
        </div>
      <% end %>

      <div
        class="details-handle"
        id="details-handle"
        phx-hook="DetailsResize"
        style={"right: #{@details_width - 4}px"}
      >
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
          <div class="conv-scroll" id="conv-scroll" phx-hook="ScrollFollow">
            <%= if @workspace_active do %>
              <%= for rendered <- DshBeam.Ui.render_slot(:conversation, assigns, key: @view_tab) do %>
                <%= rendered %>
              <% end %>
            <% else %>
              <div class="conversation-empty">
                <p class="empty-title">no workspace open</p>
                <p class="muted">pick a folder in the sidebar and press “+ new session” to start a conversation</p>
              </div>
            <% end %>
            <div class="composer-seat">
              <%= if @workspace_active do %>
                <div class="to-bottom-wrap">
                  <button type="button" class="to-bottom" aria-label="scroll to bottom">▾</button>
                </div>
                <form class="composer" phx-submit="ask">
                  <div class="composer-toolbar">
                    <%= for rendered <- DshBeam.Ui.render_slot(:composer_toolbar, assigns) do %>
                      <%= rendered %>
                    <% end %>
                  </div>
                  <textarea
                    name="text"
                    id="composer-textarea"
                    phx-hook="AutoGrow"
                    rows="1"
                    placeholder="run a task (drives the agent loop)"
                    disabled={@chat_busy}
                  ><%= @chat_text %></textarea>
                  <div class="composer-actions">
                    <%= if @chat_busy do %>
                      <button type="button" class="composer-send" phx-click="stop_chat">stop</button>
                    <% else %>
                      <button type="submit" class="composer-send">send</button>
                    <% end %>
                  </div>
                </form>
              <% else %>
                <div class="composer composer-inert">
                  <textarea disabled placeholder="open a workspace to start"></textarea>
                  <button type="button" disabled class="composer-send">send</button>
                </div>
              <% end %>
            </div>
          </div>
        </div>
      </div>

      <div class="frame-details">
        <%= for rendered <- DshBeam.Ui.render_slot(:details, assigns) do %>
          <%= rendered %>
        <% end %>
      </div>
    </div>

    <%= if @settings_open do %>
      <div
        class="settings-overlay"
        data-dsh-region
        data-dsh-slot="layout"
        data-dsh-plugin="DshBeamWeb.ConsoleLive"
        data-dsh-source="lib/dsh_beam_web/console_live.ex"
      >
        <div class="settings-backdrop" phx-click="close_settings"></div>
        <div class="settings-panel">
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
            <%= for rendered <- DshBeam.Ui.render_slot(:settings_section, assigns, key: @settings_section) do %>
              <%= rendered %>
            <% end %>
          </div>
        </div>
      </div>
    <% end %>

    <%= if @picker_open do %>
      <div
        class="settings-overlay"
        data-dsh-region
        data-dsh-slot="layout"
        data-dsh-plugin="DshBeamWeb.ConsoleLive"
        data-dsh-source="lib/dsh_beam_web/console_live.ex"
      >
        <div class="settings-backdrop" phx-click="picker_cancel"></div>
        <div class="settings-panel picker-panel">
          <div class="picker-head">
            <span class="picker-title">choose a workspace folder</span>
            <button phx-click="picker_cancel">cancel</button>
          </div>
          <div class="picker-path"><code><%= @picker_path %></code></div>
          <div class="picker-list">
            <button class="picker-entry" phx-click="picker_nav" phx-value-path={Path.dirname(@picker_path)}>
              ../ (up)
            </button>
            <%= for dir <- @picker_entries do %>
              <button class="picker-entry" phx-click="picker_nav" phx-value-path={dir.path}>
                📁 <%= dir.name %>
              </button>
            <% end %>
            <%= if @picker_entries == [] do %>
              <p class="muted">no subdirectories here</p>
            <% end %>
          </div>
          <div class="picker-foot">
            <button class="new-session-btn" phx-click="picker_select">select this folder</button>
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

  # Subdirectories of a path, sorted by name — the server-side folder picker
  # browses the local filesystem and returns real absolute paths (the browser
  # File System Access API cannot expose a picked folder's path).
  defp list_dirs(path) do
    case File.ls(path) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&File.dir?(Path.join(path, &1)))
        |> Enum.map(fn name -> %{name: name, path: Path.join(path, name)} end)
        |> Enum.sort_by(& &1.name)

      {:error, _} ->
        []
    end
  end

  defp persist_llm(runtime, base_url, model, credential, receive_timeout) do
    store = DshBeam.Runtime.settings(runtime)

    :ok == DshBeam.Settings.put(store, DshBeam.Llm.Plugin, :base_url, base_url) and
      :ok == DshBeam.Settings.put(store, DshBeam.Llm.Plugin, :model, model) and
      (is_nil(credential) or
         :ok == DshBeam.Settings.put(store, DshBeam.Llm.Plugin, :credential, credential)) and
      (is_nil(receive_timeout) or
         :ok == DshBeam.Settings.put(store, DshBeam.Llm.Plugin, :receive_timeout, receive_timeout))
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

    # DshBeam.Llm.config/1 is a synchronous call into the LLM fiber, which is
    # BLOCKED for the whole turn while it streams the model reply. Querying it
    # here would therefore freeze every refresh (and the stop button) until the
    # stream ends. Reuse the last-known config while a chat is in flight; it
    # cannot change mid-turn anyway (the composer is busy), and it re-syncs the
    # moment the turn settles.
    llm_config =
      if socket.assigns.chat_busy do
        socket.assigns.llm_config
      else
        case DshBeam.Context.get(socket.assigns.ctx, :llm) do
          {:ok, llm} when is_pid(llm) -> DshBeam.Llm.config(llm)
          _ -> nil
        end
      end

    {credential_mode, credential_env} =
      case llm_config && llm_config.credential do
        {:literal, _} -> {"literal", ""}
        {:env, name} -> {"env", name}
        _ -> {"env", "DEEPSEEK_API_KEY"}
      end

    store = DshBeam.Runtime.settings(runtime)
    default_preset = resolve_default_preset(store)
    workspace_sessions = workspace_sessions(socket.assigns.ctx)
    workspace_active = Enum.any?(workspace_sessions, & &1.current)

    chat = chat_entries(socket.assigns.ctx, socket.assigns.chat_busy, socket.assigns.open_rows)

    assign(socket,
      rows: rows,
      bindings: bindings,
      llm_config: llm_config,
      credential_mode: credential_mode,
      credential_env: credential_env,
      chat_log: chat,
      todos: todos(socket.assigns.ctx),
      trajectory: trajectory(socket.assigns.ctx, socket.assigns.trajectory_query),
      permission: permission(socket.assigns.ctx),
      workspace_sessions: workspace_sessions,
      workspace_active: workspace_active,
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
    case alive_session(ctx) do
      {:ok, session} ->
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
  defp chat_entries(ctx, busy, open_rows) do
    case alive_session(ctx) do
      {:ok, session} ->
        # idempotent: once subscribed, appends fan out {:dsh_session_event, ...}
        # and re-render the pane incrementally (reactive coeffect, not polling)
        _ = DshBeam.Session.subscribe(session)

        session
        |> DshBeam.Session.all()
        # only the user-visible conversation roles belong in the chat pane;
        # structural/ledger roles (turn/request/todo/permission/…) live in their
        # own projections (trajectory, todo panel, access seat).
        |> Enum.filter(&chat_role?(&1["role"]))
        |> group_reasoning(busy)
        |> Enum.with_index()
        |> Enum.map(fn {event, i} ->
          id = "chat-entry-#{i}"

          event
          |> chat_entry()
          |> Map.put(:id, id)
          |> Map.put(:open, MapSet.member?(open_rows, id))
        end)

      _ ->
        []
    end
  end

  # Chat-only update on one session append: re-derive the chat projection from
  # the (in-memory) session log without recomputing the whole console. The
  # expensive work (plugin inventory, LLM config, workspace roster) is skipped
  # here, so a streamed delta re-renders only the conversation pane.
  defp refresh_chat(socket, %{"role" => "todo_write"}),
    do: assign(socket, todos: todos(socket.assigns.ctx))

  defp refresh_chat(socket, %{"role" => "permission_preset"}),
    do: assign(socket, permission: permission(socket.assigns.ctx))

  defp refresh_chat(socket, %{"role" => role}) when role in ["turn_start", "turn_end", "request"],
    do: socket

  defp refresh_chat(socket, _event) do
    assign(
      socket,
      :chat_log,
      chat_entries(socket.assigns.ctx, socket.assigns.chat_busy, socket.assigns.open_rows)
    )
  end

  # Streamed reasoning is many reasoning_chunk events; fold consecutive chunks
  # into one entry. `running` marks the live tail while the loop is still
  # streaming (the collapsed row then follows the latest line, not the first).
  defp group_reasoning(events, busy) do
    {grouped, current} =
      Enum.reduce(events, {[], nil}, fn
        %{"role" => "reasoning_chunk", "content" => content}, {acc, current} ->
          {acc, (current || "") <> content}

        event, {acc, current} ->
          # a reasoning block closed by another event is settled, never the
          # streaming tail
          acc = if current, do: [reasoning_entry(current, false) | acc], else: acc
          {[event | acc], nil}
      end)

    # only the final (still-open) block is the live tail
    grouped = if current, do: [reasoning_entry(current, busy) | grouped], else: grouped
    Enum.reverse(grouped)
  end

  defp reasoning_entry(content, busy),
    do: %{"role" => "reasoning_chunk", "content" => content, "running" => busy}

  defp chat_entry(%{"role" => "user", "content" => content}),
    do: %{kind: :user, content: content}

  defp chat_entry(%{"role" => "assistant", "content" => content}),
    do: %{kind: :assistant, content: content}

  defp chat_entry(%{"role" => "reasoning_chunk", "content" => content} = event),
    do: %{kind: :reasoning, content: content, running: Map.get(event, "running", false)}

  defp chat_entry(%{"role" => "tool_call", "name" => name, "arguments" => args}),
    do: %{kind: :tool_call, name: name, command: tool_command(name, args)}

  defp chat_entry(%{"role" => "tool_result", "name" => name, "content" => content}),
    do: %{kind: :tool_result, name: name, content: content}

  defp chat_entry(%{"role" => "error", "content" => content}),
    do: %{kind: :error, content: content}

  defp chat_entry(%{"role" => "command_run", "name" => name, "args" => args}),
    do: %{kind: :command_run, name: name, args: args}

  defp chat_entry(%{"role" => "command_done", "name" => name, "content" => content}),
    do: %{kind: :command_done, name: name, content: content}

  defp chat_entry(other), do: %{kind: :event, content: inspect(other)}

  # The roles the chat pane renders; everything else (structural/ledger roles)
  # is a different projection.
  defp chat_role?(role) do
    role in [
      "user",
      "assistant",
      "reasoning_chunk",
      "tool_call",
      "tool_result",
      "error",
      "command_run",
      "command_done"
    ]
  end

  # The readable invocation of a tool call: the bash command verbatim, and any
  # other tool's arguments as a compact term (instead of the raw map inspect).
  defp tool_command(_name, args) when is_map(args) do
    case Map.get(args, "command") do
      command when is_binary(command) -> command
      _ -> inspect(args)
    end
  end

  defp tool_command(_name, args), do: inspect(args)

  # The trajectory is the same session log grouped by turn: a "user" event opens
  # a turn; the tool calls, results, and the answer that follow belong to it.
  defp trajectory(ctx, query) do
    case alive_session(ctx) do
      {:ok, session} ->
        session
        |> DshBeam.Session.all()
        |> DshBeam.Ui.TrajectoryProjection.from_events()
        |> DshBeam.Ui.TrajectoryProjection.filter(query)

      _ ->
        []
    end
  end

  # The current :session, only while its process is alive. Closing a session
  # (e.g. the current workspace session) kills its pid, but the :session
  # binding can briefly keep the stale pid — reading or subscribing to it
  # would raise :noproc and crash the console.
  defp alive_session(ctx) do
    case DshBeam.Context.get(ctx, :session) do
      {:ok, session} when is_pid(session) ->
        if Process.alive?(session), do: {:ok, session}, else: :dead

      _ ->
        :none
    end
  end

  # The permission-preset value the "Access" seat renders (the reference's
  # `permissions` projection), folded from the current session's log.
  defp permission(ctx) do
    case alive_session(ctx) do
      {:ok, session} -> DshBeam.Permission.select_for(session)
      _ -> %{current_value: DshBeam.Permission.default_preset(), options: []}
    end
  end

  # The single write path for a permission pick: append the durable
  # permission_preset event to the current session (the reference's
  # command('/permission <id>') → permission/preset log event).
  defp apply_permission(socket, preset) do
    case alive_session(socket.assigns.ctx) do
      {:ok, session} -> DshBeam.Permission.apply(session, preset)
      _ -> :ok
    end

    socket
  end

  # The model/effort write path: re-arm the LLM provider in-memory and persist
  # the choice to the settings store, so it survives a restart.
  defp apply_model(socket, opts) do
    case DshBeam.Context.get(socket.assigns.ctx, :llm) do
      {:ok, llm} when is_pid(llm) ->
        :ok = DshBeam.Llm.configure(llm, opts)

        store = DshBeam.Runtime.settings(socket.assigns.runtime)

        Enum.each(opts, fn {key, value} ->
          DshBeam.Settings.put(store, DshBeam.Llm.Plugin, key, value)
        end)

      _ ->
        :ok
    end

    socket
  end

  # Slash-command execution: append a durable command_run/command_done pair
  # (the reference's command/run + command/done log events) around the
  # dispatch, then re-render. The result string becomes the command card body.
  # Run the whole model↔tool loop off the LiveView process: the loop makes a
  # real HTTP call (up to the receive_timeout budget, default 300s), which must
  # not block the event handler and freeze the chat pane. The result is pushed
  # back as a message and rendered in handle_info/2. A per-turn cancellation
  # token rides alongside: the loop polls it at its step boundaries, and the
  # adapter polls it while the transport runs, so "stop" truly halts the turn.
  defp ask_agent(socket, text) do
    case loop_pid(socket.assigns.runtime) do
      {:ok, loop} ->
        from = self()

        turn = make_ref()
        token = DshBeam.Agent.Cancel.new()

        {:ok, task} =
          Task.start(fn ->
            result = DshBeam.Agent.Loop.run_trace(loop, text, token)
            send(from, {:chat_result, turn, text, result})
          end)

        # Watchdog: a result (or the user's stop) cancels the turn-scoped guard
        # implicitly — a stale guard finds chat_turn already reset and is
        # ignored. Only a truly hung loop is cleared here.
        Process.send_after(self(), {:chat_guard, turn}, @chat_result_timeout_ms)

        {:noreply,
         socket
         |> assign(
           chat_text: "",
           chat_busy: true,
           chat_task: task,
           chat_turn: turn,
           chat_token: token,
           chat_started_at: System.system_time(:second)
         )
         |> refresh()}

      :not_found ->
        {:noreply, socket |> assign(chat_text: "", chat_error: ":no_loop_plugin") |> refresh()}
    end
  end

  defp run_command(socket, name, args) do
    session = alive_session(socket.assigns.ctx)

    append_command_event(session, %{"role" => "command_run", "name" => name, "args" => args})

    {socket, result} = dispatch_command(socket, name, args)

    append_command_event(session, %{"role" => "command_done", "name" => name, "content" => result})

    {:noreply, socket |> assign(chat_text: "", chat_error: nil) |> refresh()}
  end

  defp append_command_event({:ok, session}, event), do: DshBeam.Session.append(session, event)
  defp append_command_event(_none, _event), do: :ok

  defp dispatch_command(socket, "permission", args) do
    presets = ["read-only", "workspace-write", "danger-full-access"]

    if args in presets do
      apply_permission(socket, args)
      {socket, "preset #{args}"}
    else
      {socket, "unknown preset \"#{args}\" (available: #{Enum.join(presets, ", ")})"}
    end
  end

  defp dispatch_command(socket, "model", args) do
    if DshBeam.Llm.Models.find_model(args) do
      apply_model(socket, model: args)
      {socket, "model #{args}"}
    else
      {socket, "unknown model \"#{args}\""}
    end
  end

  defp dispatch_command(socket, "goal", args) do
    result =
      case alive_session(socket.assigns.ctx) do
        {:ok, session} -> goal_command(socket.assigns.ctx, session, String.trim(args))
        _ -> "no session"
      end

    {socket, result}
  end

  defp dispatch_command(socket, "clear", _args) do
    case alive_session(socket.assigns.ctx) do
      {:ok, session} -> DshBeam.Session.clear(session)
      _ -> :ok
    end

    {socket, "conversation cleared"}
  end

  defp dispatch_command(socket, "help", _args) do
    {socket, "commands: " <> Enum.join(DshBeam.Command.names(), ", ")}
  end

  defp dispatch_command(socket, name, _args) do
    {socket, "unknown command \"/#{name}\" (try /help)"}
  end

  # -- /goal command (the reference's command-goal) --

  defp goal_command(_ctx, session, ""), do: goal_status(session)

  defp goal_command(ctx, session, args) do
    {word, rest} = split_word(args)
    word = String.downcase(word)

    cond do
      word == "edit" ->
        if String.trim(rest) == "",
          do: "edit needs a replacement objective",
          else: goal_edit(ctx, session, String.trim(rest))

      word in ["pause", "resume", "clear"] and rest == "" ->
        goal_verb(ctx, session, word)

      word in ["pause", "resume", "clear"] ->
        "unknown /goal form \"#{args}\" (try /goal <objective|edit <objective>|pause|resume|clear>)"

      true ->
        goal_create(ctx, session, args)
    end
  end

  defp split_word(args) do
    case String.split(args, " ", parts: 2) do
      [word, rest] -> {word, rest}
      [word] -> {word, ""}
      [] -> {"", ""}
    end
  end

  defp goal_status(session) do
    case DshBeam.Goal.current(session) do
      nil ->
        "no current goal — /goal <objective> to create one"

      goal ->
        round = "#{goal["rounds_started"]}/#{goal["max_goal_rounds"]}"
        base = "goal [#{goal["phase"]}]: #{goal["objective"]} (round #{round})"

        case goal["blocked_reason"] do
          %{"code" => code, "message" => message} ->
            base <> " — blocked: #{code} (#{message})"

          _ ->
            base
        end
    end
  end

  defp goal_create(ctx, session, objective) do
    case DshBeam.Goal.create(session, objective) do
      {:ok, goal} ->
        DshBeam.Goal.Driver.arm_ctx(ctx)
        "goal created: #{goal["objective"]}"

      {:error, :goal_already_current} ->
        "a goal is already current — /goal edit <objective> or /goal clear"

      {:error, :empty_objective} ->
        "objective must not be empty"

      {:error, reason} ->
        "create failed: #{inspect(reason)}"
    end
  end

  defp goal_edit(ctx, session, objective) do
    goal_update(ctx, session, "edit", objective: objective)
  end

  defp goal_verb(ctx, session, "clear"), do: goal_clear(ctx, session)
  defp goal_verb(ctx, session, verb), do: goal_update(ctx, session, verb, [])

  defp goal_clear(ctx, session) do
    case DshBeam.Goal.current(session) do
      nil ->
        "no current goal"

      goal ->
        case DshBeam.Goal.clear(session, goal["id"], goal["revision"]) do
          {:ok, :cleared} ->
            DshBeam.Goal.Driver.disarm_ctx(ctx)
            "goal cleared"

          {:error, reason} ->
            "clear failed: #{inspect(reason)}"
        end
    end
  end

  defp goal_update(ctx, session, action, opts) do
    case DshBeam.Goal.current(session) do
      nil ->
        "no current goal"

      goal ->
        case DshBeam.Goal.update(session, goal["id"], goal["revision"], action, opts) do
          {:ok, updated} ->
            apply_command_activation(ctx, action)
            "goal [#{updated["phase"]}]: #{updated["objective"]}"

          {:error, :invalid_transition} ->
            "cannot #{action} from phase #{goal["phase"]}"

          {:error, :blocked_reason_required} ->
            "blocked needs a concrete reason"

          {:error, reason} ->
            "#{action} failed: #{inspect(reason)}"
        end
    end
  end

  defp apply_command_activation(ctx, "resume"), do: DshBeam.Goal.Driver.arm_ctx(ctx)

  defp apply_command_activation(ctx, action) when action in ["pause", "complete", "blocked"],
    do: DshBeam.Goal.Driver.disarm_ctx(ctx)

  defp apply_command_activation(_ctx, _action), do: :ok

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
        entries:
          panel_entries() ++
            core_entries([
              :session,
              :llm,
              :adapter,
              :shell,
              :bash,
              :goal,
              :goal_driver,
              :tool_plugin,
              :loop
            ])
      },
      %{
        id: "chat",
        name: "Chat",
        desc: "Session + llm + adapter + loop (no tools)",
        entries: panel_entries() ++ core_entries([:session, :llm, :adapter, :tool_plugin, :loop])
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

    # present = the plugin is an entry of this composition (running or
    # disabled); enabled = present and its disabled flag is false.
    present = MapSet.new(entries, fn {_id, rec} -> rec.spec.plugin end)

    enabled =
      for {_id, %{spec: %{plugin: plugin, disabled: false}}} <- entries,
          into: MapSet.new(),
          do: plugin

    DshBeam.Plugin.Inventory.installed()
    |> Enum.map(fn entry ->
      plugin = entry.plugin
      drafts = Map.get(plugin_drafts, plugin, %{})

      %{
        plugin: plugin,
        name: friendly_plugin_name(plugin),
        present: MapSet.member?(present, plugin),
        enabled: MapSet.member?(enabled, plugin),
        # the console host is the composition's root: never disableable
        core: plugin == DshBeam.Console,
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
