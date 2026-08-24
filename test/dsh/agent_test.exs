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

  # The loop now records structural events (turn_start/request/turn_end); the
  # content assertions below care only about the user-visible events.
  defp content_events(events) do
    Enum.reject(events, &(&1["role"] in ["turn_start", "turn_end", "request"]))
  end

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

    # the assistant tool-call turn uses "" content (never nil), so the wire
    # message and the session projection stay identical (some gateways reject
    # a null content, and a nil would poison later replays)
    [assistant_turn] = Enum.filter(second_messages, &(&1["role"] == "assistant"))
    assert assistant_turn["content"] == ""

    # the turn was logged to the session (the single source of truth), with
    # the tool call and result recorded chronologically: user, tool_call,
    # tool_result, assistant.
    {:ok, session} = DshBeam.Context.get(ctx, :session)
    assert content_events(DshBeam.Session.all(session)) |> length() == 4

    assert [
             %{"role" => "user"},
             %{"role" => "tool_call"},
             %{"role" => "tool_result"},
             %{"role" => "assistant"}
           ] =
             content_events(DshBeam.Session.all(session))

    # the structural events wrap the content: one turn, one request per model
    # call (the scripted adapter is called twice), and a completed turn_end
    assert DshBeam.Session.all(session) |> Enum.count(&(&1["role"] == "turn_start")) == 1
    assert DshBeam.Session.all(session) |> Enum.count(&(&1["role"] == "request")) == 2

    assert [%{"role" => "turn_end", "reason" => "completed"}] =
             DshBeam.Session.all(session) |> Enum.filter(&(&1["role"] == "turn_end"))
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

    # the second turn's FIRST model call must carry the first turn's history —
    # including the tool turn (assistant tool_calls + the tool result), so the
    # prompt prefix is stable across runs (cache-friendly, deriveMessages-like)
    assert_receive {:loop_call, first_messages, _opts}, 1000

    assert Enum.any?(first_messages, &(&1["role"] == "user" and &1["content"] == "first task"))

    assert Enum.any?(
             first_messages,
             &(&1["role"] == "assistant" and &1["content"] == "final answer")
           )

    assert Enum.any?(
             first_messages,
             &(&1["role"] == "assistant" and &1["tool_calls"] != nil)
           )

    assert Enum.any?(first_messages, &(&1["role"] == "tool"))

    assert Enum.any?(first_messages, &(&1["role"] == "user" and &1["content"] == "second task"))

    # the session log accumulated both turns: turn 1 = user, tool_call,
    # tool_result, assistant (4 content events); turn 2 = user, assistant — 6
    # content events total, plus two turn_start/turn_end pairs.
    ctx = DshBeam.Runtime.context(runtime)
    {:ok, session} = DshBeam.Context.get(ctx, :session)
    assert content_events(DshBeam.Session.all(session)) |> length() == 6
    assert DshBeam.Session.all(session) |> Enum.count(&(&1["role"] == "turn_start")) == 2
  end

  test "the projection round-trips a tool turn into the model wire shape" do
    {:ok, session} = DshBeam.Session.Memory.start([])

    events = [
      %{"role" => "user", "content" => "first"},
      %{
        "role" => "tool_call",
        "id" => "c1",
        "name" => "loop_echo",
        "arguments" => %{"text" => "hi"},
        "arguments_json" => ~s({"text":"hi"})
      },
      %{
        "role" => "tool_result",
        "tool_call_id" => "c1",
        "name" => "loop_echo",
        "content" => "echo:hi"
      },
      %{"role" => "assistant", "content" => "final answer"}
    ]

    Enum.each(events, &DshBeam.Session.append(session, &1))

    assert DshBeam.Agent.Loop.Projection.from_session(session) == [
             %{"role" => "user", "content" => "first"},
             %{
               "role" => "assistant",
               "content" => "",
               "tool_calls" => [
                 %{
                   "id" => "c1",
                   "type" => "function",
                   "function" => %{"name" => "loop_echo", "arguments" => ~s({"text":"hi"})}
                 }
               ]
             },
             %{"role" => "tool", "tool_call_id" => "c1", "content" => "echo:hi"},
             %{"role" => "assistant", "content" => "final answer"}
           ]
  end

  test "the loop records a reasoning block and usage from the reply" do
    adapter = %{id: :adapter, plugin: ReasoningLlmAdapter, config: [], disabled: false}

    {:ok, runtime} =
      DshBeam.Runtime.start_link(
        [session_entry(), llm_entry(), adapter, loop_entry()],
        []
      )

    %{loop: %{pid: loop}} = DshBeam.Runtime.entries(runtime)
    ctx = DshBeam.Runtime.context(runtime)
    {:ok, session} = DshBeam.Context.get(ctx, :session)

    assert {:ok, "answer"} = DshBeam.Agent.Loop.run(loop, "think")

    events = DshBeam.Session.all(session)

    # reasoning is a display-only event, just before the assistant answer
    assert [
             %{"role" => "reasoning", "content" => "chain of thought"},
             %{"role" => "assistant", "content" => "answer"} | _
           ] =
             Enum.drop_while(events, &(&1["role"] != "reasoning"))

    [assistant] = Enum.filter(events, &(&1["role"] == "assistant"))
    assert assistant["usage"].input_tokens == 100
    assert assistant["usage"].output_tokens == 50
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

defmodule ReasoningLlmAdapter do
  @moduledoc false
  # Scripted adapter returning a reasoning block and disjoint usage, to assert
  # the loop records them as a reasoning event + usage on the assistant event.
  use DshBeam.Llm.Adapter

  @impl true
  def complete(_config, _messages, _opts) do
    {:ok,
     %{
       content: "answer",
       reasoning: "chain of thought",
       tool_calls: [],
       finish_reason: :stop,
       usage: %{
         input_tokens: 100,
         output_tokens: 50,
         cache_read_tokens: 20,
         cache_write_tokens: 0,
         reasoning_tokens: 30
       }
     }}
  end
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
