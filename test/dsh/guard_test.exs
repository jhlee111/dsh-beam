defmodule DshBeam.GuardTest do
  use ExUnit.Case, async: false

  # --- timeout-policy ---

  test "a tool that returns quickly is untouched" do
    {:ok, provider} = mount_tool(FastTool)
    {:ok, result} = DshBeam.Guard.TimeoutPolicy.invoke(provider, :fast, %{}, 500)
    assert result == "fast-done"
  end

  test "a tool that exceeds its budget returns a TOOL_TIMEOUT result" do
    {:ok, provider} = mount_tool(SlowTool)
    {:ok, result} = DshBeam.Guard.TimeoutPolicy.invoke(provider, :slow, %{}, 20)
    assert result =~ "timed out after 20ms"
  end

  test "a tool with no budget delegates without a deadline" do
    {:ok, provider} = mount_tool(FastTool)
    {:ok, result} = DshBeam.Guard.TimeoutPolicy.invoke(provider, :fast, %{}, nil)
    assert result == "fast-done"
  end

  # --- repeat-tool-reminder ---

  test "consecutive identical calls trigger the reminder at the configured threshold" do
    state = DshBeam.Guard.RepeatToolReminder.new()

    {s1, nil} = DshBeam.Guard.RepeatToolReminder.track(state, "bash", %{"command" => "ls"})
    {s2, nil} = DshBeam.Guard.RepeatToolReminder.track(s1, "bash", %{"command" => "ls"})
    {_s3, reminder} = DshBeam.Guard.RepeatToolReminder.track(s2, "bash", %{"command" => "ls"})

    assert reminder =~ "repeating"
  end

  test "argument order does not matter (canonicalization)" do
    state = DshBeam.Guard.RepeatToolReminder.new()

    {s1, nil} = DshBeam.Guard.RepeatToolReminder.track(state, "edit", %{"a" => 1, "b" => 2})
    {s2, nil} = DshBeam.Guard.RepeatToolReminder.track(s1, "edit", %{"b" => 2, "a" => 1})
    {_s3, reminder} = DshBeam.Guard.RepeatToolReminder.track(s2, "edit", %{"a" => 1, "b" => 2})

    # three identical (modulo order) calls: run=3 hits the threshold
    assert reminder =~ "repeating"
  end

  test "a different tool resets the run" do
    state = DshBeam.Guard.RepeatToolReminder.new()

    {s1, nil} = DshBeam.Guard.RepeatToolReminder.track(state, "bash", %{"command" => "ls"})
    {s2, nil} = DshBeam.Guard.RepeatToolReminder.track(s1, "bash", %{"command" => "ls"})
    {s3, nil} = DshBeam.Guard.RepeatToolReminder.track(s2, "read", %{"path" => "x"})
    {_s4, reminder} = DshBeam.Guard.RepeatToolReminder.track(s3, "read", %{"path" => "x"})

    # run reset by the tool change; the second "read" is only run=2, below threshold
    assert reminder == nil
  end

  # --- helpers ---

  defp mount_tool(plugin) do
    entry = %{id: :tool, plugin: plugin, config: [], disabled: false}
    {:ok, runtime} = DshBeam.Runtime.start_link([entry], [])
    ctx = DshBeam.Runtime.context(runtime)

    tool_name =
      case plugin do
        FastTool -> :fast
        SlowTool -> :slow
      end

    DshBeam.Context.get(ctx, tool_name)
  end
end

defmodule FastTool do
  @moduledoc false
  use DshBeam.Plugin

  tool(:fast, description: "fast", parameters: %{})

  @impl DshBeam.Plugin
  def handle_dsh_tool_call(:fast, _args, _state), do: {:ok, "fast-done"}
end

defmodule SlowTool do
  @moduledoc false
  use DshBeam.Plugin

  tool(:slow, description: "slow", parameters: %{})

  @impl DshBeam.Plugin
  def handle_dsh_tool_call(:slow, _args, _state) do
    Process.sleep(500)
    {:ok, "slow-done"}
  end
end
