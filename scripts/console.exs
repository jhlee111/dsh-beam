# The live console demo: boots the runtime with the console plugin (HTTP
# listener on 127.0.0.1:4888, override with DSH_BEAM_PORT) plus the full
# agent composition — session, llm,
# shell, tool-bash, tool-fs, and the agent loop.
#
#   DEEPSEEK_API_KEY=sk-... mix run scripts/console.exs
#
# The llm provider talks to real deepseek-chat via the DEEPSEEK_API_KEY
# environment variable (resolved per request). Without it, the chat pane
# reports {:error, {:missing_env, "DEEPSEEK_API_KEY"}}.
entries = [
  %{id: :console, plugin: DshBeam.Console, config: [server: true], disabled: false},
  %{id: :session, plugin: DshBeam.Session.Plugin, config: [], disabled: false},
  %{id: :workspace, plugin: DshBeam.Workspace, config: [], disabled: false},
  %{id: :llm, plugin: DshBeam.Llm.Plugin, config: [], disabled: false},
  %{id: :adapter, plugin: DshBeam.Llm.Adapter.Req, config: [], disabled: false},
  %{id: :shell, plugin: DshBeam.Shell.Plugin, config: [], disabled: false},
  %{id: :bash, plugin: DshBeam.Tool.Bash, config: [], disabled: false},
  %{id: :fs, plugin: DshBeam.Tool.Fs, config: [root: File.cwd!()], disabled: false},
  %{id: :todo, plugin: DshBeam.Tool.Todo, config: [], disabled: false},
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
  %{id: :panel_trajectory, plugin: DshBeam.Ui.Panel.Trajectory, config: [], disabled: false}
]

# Persist the settings store (model/credential overrides) to disk, so a saved
# model/API key survives a console restart. Without this the store is in-memory.
settings_path = Path.join([File.cwd!(), ".dsh", "settings.json"])

{:ok, runtime} =
  DshBeam.Runtime.start_link(entries, settings_path: settings_path)

# Load saved plugins (~/.dsh/plugins/*.exs) so a plugin saved in one workspace
# is available in every other project the console opens.
saved = DshBeam.Creator.load_saved_plugins(runtime)
IO.puts("loaded saved plugins: #{inspect(saved)}")

IO.puts(
  "dsh-beam console: http://127.0.0.1:#{DshBeam.Console.port()} (runtime #{inspect(runtime)})"
)

IO.puts(
  "settings: #{settings_path} (port override: DSH_BEAM_PORT=#{System.get_env("DSH_BEAM_PORT") || "unset"})"
)

Process.sleep(:infinity)
