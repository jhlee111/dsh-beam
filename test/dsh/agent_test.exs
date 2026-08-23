defmodule DshBeam.AgentTest do
  use ExUnit.Case, async: false

  defp session_entry,
    do: %{id: :session, plugin: DshBeam.Session.Plugin, config: [], disabled: false}

  defp llm_entry do
    %{
      id: :llm,
      plugin: DshBeam.Llm.Plugin,
      config: [adapter_config: %{parent: self()}],
      disabled: false
    }
  end

  defp adapter_entry do
    %{id: :adapter, plugin: LoopLlmAdapter, config: [parent: self()], disabled: false}
  end

  defp tool_entry, do: %{id: :echo, plugin: LoopEchoTool, config: [], disabled: false}

  defp loop_entry, do: %{id: :loop, plugin: DshBeam.Agent.Loop, config: [], disabled: false}

  test "the loop dispatches a tool call and answers" do
    {:ok, runtime} =
      DshBeam.Runtime.start_link(
        [session_entry(), llm_entry(), adapter_entry(), tool_entry(), loop_entry()],
        []
      )

    ctx = DshBeam.Runtime.context(runtime)

    # the loop is a consumer (not a capability): fetch it from the composition
    %{loop: %{pid: loop}} = DshBeam.Runtime.entries(runtime)

    assert {:ok, "final answer"} = DshBeam.Agent.Loop.run(loop, "do something")

    # the scripted model saw a tool call first, then the tool result
    assert_receive {:loop_call, first_messages, first_opts}, 1000
    assert first_opts[:tools] != []
    assert Enum.any?(first_messages, &(&1["role"] == "user"))

    assert_receive {:loop_call, second_messages, _opts}, 1000
    assert Enum.any?(second_messages, &(&1["role"] == "tool"))
    assert Enum.any?(second_messages, &(&1["role"] == "assistant" and &1["tool_calls"] != nil))

    # the turn was logged to the session (the single source of truth), with
    # the tool call and result recorded chronologically: user, tool_call,
    # tool_result, assistant.
    {:ok, session} = DshBeam.Context.get(ctx, :session)
    assert DshBeam.Session.count(session) == 4

    assert [
             %{"role" => "user"},
             %{"role" => "tool_call"},
             %{"role" => "tool_result"},
             %{"role" => "assistant"}
           ] =
             DshBeam.Session.all(session)
  end

  test "run_trace/2 returns the loop's step trace" do
    {:ok, runtime} =
      DshBeam.Runtime.start_link(
        [session_entry(), llm_entry(), adapter_entry(), tool_entry(), loop_entry()],
        []
      )

    %{loop: %{pid: loop}} = DshBeam.Runtime.entries(runtime)

    assert {:ok, "final answer", trace} = DshBeam.Agent.Loop.run_trace(loop, "do something")

    assert trace == [
             {:tool_call, "loop_echo", %{"text" => "from-loop"}},
             {:tool_result, "loop_echo", "echo:from-loop"}
           ]
  end

  test "the loop is multi-turn: prior turns replay into the model context" do
    {:ok, runtime} =
      DshBeam.Runtime.start_link(
        [session_entry(), llm_entry(), adapter_entry(), tool_entry(), loop_entry()],
        []
      )

    %{loop: %{pid: loop}} = DshBeam.Runtime.entries(runtime)

    assert {:ok, "final answer"} = DshBeam.Agent.Loop.run(loop, "first task")

    # drain the two scripted calls for the first turn (tool + answer)
    assert_receive {:loop_call, _m, _opts}, 1000
    assert_receive {:loop_call, _m, _opts}, 1000

    assert {:ok, "final answer"} = DshBeam.Agent.Loop.run(loop, "second task")

    # the second turn's FIRST model call must carry the first turn's history
    assert_receive {:loop_call, first_messages, _opts}, 1000

    assert Enum.any?(first_messages, &(&1["role"] == "user" and &1["content"] == "first task"))

    assert Enum.any?(
             first_messages,
             &(&1["role"] == "assistant" and &1["content"] == "final answer")
           )

    assert Enum.any?(first_messages, &(&1["role"] == "user" and &1["content"] == "second task"))

    # the session log accumulated both turns, each with user + tool_call +
    # tool_result + assistant (8 events total)
    ctx = DshBeam.Runtime.context(runtime)
    {:ok, session} = DshBeam.Context.get(ctx, :session)
    assert DshBeam.Session.count(session) == 8
  end
end

defmodule LoopEchoTool do
  @moduledoc false
  use DshBeam.Plugin

  tool(:loop_echo,
    description: "echo the input",
    parameters: %{"type" => "object", "properties" => %{"text" => %{"type" => "string"}}}
  )

  @impl DshBeam.Plugin
  def handle_dsh_tool_call(:loop_echo, %{"text" => text}, _state), do: {:ok, "echo:" <> text}
end

defmodule LoopLlmAdapter do
  @moduledoc false
  use DshBeam.Llm.Adapter

  @impl true
  def complete(config, messages, opts) do
    send(Map.get(config, :parent, self()), {:loop_call, messages, opts})

    if Enum.any?(messages, &(&1["role"] == "tool")) do
      {:ok, %{content: "final answer", tool_calls: [], finish_reason: :stop, usage: nil}}
    else
      {:ok,
       %{
         content: nil,
         tool_calls: [%{id: "call_1", name: "loop_echo", arguments: ~s({"text":"from-loop"})}],
         finish_reason: :tool_calls,
         usage: nil
       }}
    end
  end
end
