# Real-API e2e smoke test: stream deepseek-reasoner and print the reasoning
# live, then the final completion. Does not touch the agent loop — it drives
# DshBeam.Llm + the Req adapter directly, so it isolates the streaming path.
#
#   DEEPSEEK_API_KEY=sk-... mix run scripts/e2e_smoke.exs
#   DEEPSEEK_API_KEY=sk-... DEEPSEEK_MODEL=deepseek-chat mix run scripts/e2e_smoke.exs

unless System.get_env("DEEPSEEK_API_KEY") do
  IO.puts("set DEEPSEEK_API_KEY (and optionally DEEPSEEK_MODEL) to run the real-API smoke test")
  System.halt(1)
end

model = System.get_env("DEEPSEEK_MODEL", "deepseek-reasoner")

{:ok, _runtime} =
  DshBeam.Runtime.start_link(
    [
      %{id: :llm, plugin: DshBeam.Llm.Plugin, config: [model: model], disabled: false},
      %{id: :adapter, plugin: DshBeam.Llm.Adapter.Req, config: [], disabled: false}
    ],
    []
  )

ctx = DshBeam.Runtime.context(_runtime)
{:ok, llm} = DshBeam.Context.get(ctx, :llm)

IO.puts("== streaming #{model} (reasoning follows live) ==")

stream = fn
  {:reasoning, chunk} ->
    IO.write(chunk)
    :ok

  _ ->
    :ok
end

result =
  DshBeam.Llm.chat(llm, [%{"role" => "user", "content" => "1+1은 얼마인가? 답만 짧게."}], stream: stream)

IO.puts("\n\n== completion ==")
IO.inspect(result, limit: :infinity, printable_limit: :infinity)
