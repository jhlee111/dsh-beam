defmodule DshBeam.ToolTest do
  use ExUnit.Case, async: false

  test "a tool declaration is introspectable" do
    assert DshBeam.Plugin.tools(TestEchoTool) == [
             %{
               name: :echo,
               description: "echo the input",
               parameters: %{
                 "type" => "object",
                 "properties" => %{"text" => %{"type" => "string"}}
               },
               timeout_ms: nil
             }
           ]
  end

  test "a tool plugin provides its tool name and answers tool calls" do
    {:ok, runtime} = DshBeam.Runtime.start_link([], [])
    entry = %{id: :echo_tool, plugin: TestEchoTool, config: [], disabled: false}
    :ok = DshBeam.Runtime.reconcile(runtime, [entry])

    ctx = DshBeam.Runtime.context(runtime)

    # the tool name is a provided capability (its fiber)
    assert {:ok, provider} = DshBeam.Context.get(ctx, :echo)
    assert {:ok, "echo:hi"} = DshBeam.Tool.call(provider, :echo, %{"text" => "hi"})

    # an unimplemented tool call is a clean error, not a crash
    assert {:error, :not_implemented} = DshBeam.Tool.call(provider, :no_such_tool, %{})
  end

  test "the tool registry lists installed tools" do
    entry = Enum.find(DshBeam.Tool.Registry.installed(), &(&1.name == :echo))
    assert entry != nil
    assert entry.plugin == TestEchoTool
    assert entry.parameters["properties"]["text"] == %{"type" => "string"}
  end
end

defmodule TestEchoTool do
  @moduledoc false
  use DshBeam.Plugin

  tool(:echo,
    description: "echo the input",
    parameters: %{"type" => "object", "properties" => %{"text" => %{"type" => "string"}}}
  )

  @impl DshBeam.Plugin
  def handle_dsh_tool_call(:echo, %{"text" => text}, _state), do: {:ok, "echo:" <> text}
end
