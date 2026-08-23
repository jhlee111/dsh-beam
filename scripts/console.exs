# The live console demo: boots the runtime with the console plugin (HTTP
# listener on 127.0.0.1:4001) plus the full agent composition — session, llm,
# shell, tool-bash, tool-fs, and the agent loop.
#
#   mix run scripts/console.exs
#
# With DEEPSEEK_API_KEY set, the llm provider talks to the real deepseek-chat
# model; without it, the Echo adapter answers offline.
adapter =
  if System.get_env("DEEPSEEK_API_KEY"),
    do: DshBeam.Llm.Adapter.Req,
    else: DshBeam.Llm.Adapter.Echo

entries = [
  %{id: :console, plugin: DshBeam.Console, config: [server: true], disabled: false},
  %{id: :session, plugin: DshBeam.Session.Plugin, config: [], disabled: false},
  %{id: :llm, plugin: DshBeam.Llm.Plugin, config: [adapter: adapter], disabled: false},
  %{id: :shell, plugin: DshBeam.Shell.Plugin, config: [], disabled: false},
  %{id: :bash, plugin: DshBeam.Tool.Bash, config: [], disabled: false},
  %{id: :fs, plugin: DshBeam.Tool.Fs, config: [root: File.cwd!()], disabled: false},
  %{id: :loop, plugin: DshBeam.Agent.Loop, config: [], disabled: false}
]

{:ok, runtime} = DshBeam.Runtime.start_link(entries, [])
IO.puts("dsh-beam console: http://127.0.0.1:4001 (runtime #{inspect(runtime)})")
Process.sleep(:infinity)
