# The live console demo: boots the runtime with the console plugin (HTTP
# listener on 127.0.0.1:4001) plus the session/llm/chat composition.
#
#   mix run scripts/console.exs
#
# With DEEPSEEK_API_KEY set, the chat pane talks to the real deepseek-chat
# model; without it, the Echo adapter answers offline.
adapter =
  if System.get_env("DEEPSEEK_API_KEY"),
    do: DshBeam.Llm.Adapter.Req,
    else: DshBeam.Llm.Adapter.Echo

entries = [
  %{id: :console, plugin: DshBeam.Console, config: [server: true], disabled: false},
  %{id: :session, plugin: DshBeam.Session.Plugin, config: [], disabled: false},
  %{id: :llm, plugin: DshBeam.Llm.Plugin, config: [adapter: adapter], disabled: false},
  %{id: :chat, plugin: DshBeam.Llm.Chat, config: [], disabled: false}
]

{:ok, runtime} = DshBeam.Runtime.start_link(entries, [])
IO.puts("dsh-beam console: http://127.0.0.1:4001 (runtime #{inspect(runtime)})")
Process.sleep(:infinity)
