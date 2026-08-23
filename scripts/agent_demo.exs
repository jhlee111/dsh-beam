# The MVP demo: session + llm + shell + tool-bash + agent loop running a task
# end-to-end. Offline and deterministic: a scripted adapter emits one bash
# tool call, so the whole loop — model -> tool call -> bash -> result ->
# model -> answer — is visible. Set DEEPSEEK_API_KEY to use the real model
# instead (the Req adapter already carries tools/tool_calls).

defmodule DemoLlmAdapter do
  @behaviour DshBeam.Llm.Adapter

  @impl true
  def complete(_config, messages, _opts) do
    case Enum.find(messages, &(&1["role"] == "tool")) do
      nil ->
        IO.puts("  [llm] emits tool call: bash(ls -1)")
        {:ok,
         %{
           content: nil,
           tool_calls: [%{id: "call_1", name: "bash", arguments: ~s({"command":"ls -1"})}],
           finish_reason: :tool_calls
         }}

      tool_message ->
        IO.puts("  [llm] sees the tool result and answers")
        {:ok, %{content: "Here is the listing:\n" <> tool_message["content"], tool_calls: [], finish_reason: :stop}}
    end
  end
end

entries = [
  %{id: :session, plugin: DshBeam.Session.Plugin, config: [], disabled: false},
  %{id: :llm, plugin: DshBeam.Llm.Plugin, config: [adapter: DemoLlmAdapter], disabled: false},
  %{id: :shell, plugin: DshBeam.Shell.Plugin, config: [], disabled: false},
  %{id: :bash, plugin: DshBeam.Tool.Bash, config: [], disabled: false},
  %{id: :loop, plugin: DshBeam.Agent.Loop, config: [], disabled: false}
]

{:ok, runtime} = DshBeam.Runtime.start_link(entries, [])
ctx = DshBeam.Runtime.context(runtime)

IO.puts("== composition ==")

for {id, rec} <- DshBeam.Runtime.entries(runtime) do
  IO.puts("  #{inspect(id)}: #{inspect(rec.spec.plugin)} (restarts=#{rec.restarts})")
end

IO.puts("== run task ==")
%{loop: %{pid: loop}} = DshBeam.Runtime.entries(runtime)
IO.puts("answer: " <> inspect(DshBeam.Agent.Loop.run(loop, "list the files")))

IO.puts("== session log ==")
{:ok, session} = DshBeam.Context.get(ctx, :session)
IO.puts(inspect(DshBeam.Session.all(session)))
