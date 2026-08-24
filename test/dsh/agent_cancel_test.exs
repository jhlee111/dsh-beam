defmodule DshBeam.Agent.CancelTest do
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
    %{id: :adapter, plugin: CancelBlockingAdapter, config: [parent: self()], disabled: false}
  end

  defp tool_entry, do: %{id: :echo, plugin: CancelEchoTool, config: [], disabled: false}

  defp loop_entry, do: %{id: :loop, plugin: DshBeam.Agent.Loop, config: [], disabled: false}

  test "a token starts un-cancelled and flips to cancelled" do
    token = DshBeam.Agent.Cancel.new()
    refute DshBeam.Agent.Cancel.cancelled?(token)
    :ok = DshBeam.Agent.Cancel.cancel(token)
    assert DshBeam.Agent.Cancel.cancelled?(token)
  end

  test "a non-token (nil) reads as not cancelled" do
    refute DshBeam.Agent.Cancel.cancelled?(nil)
  end

  test "a pre-cancelled token stops the loop before the first model call" do
    {:ok, runtime} =
      DshBeam.Runtime.start_link(
        [session_entry(), llm_entry(), adapter_entry(), tool_entry(), loop_entry()],
        []
      )

    %{loop: %{pid: loop}} = DshBeam.Runtime.entries(runtime)
    ctx = DshBeam.Runtime.context(runtime)
    {:ok, session} = DshBeam.Context.get(ctx, :session)

    token = DshBeam.Agent.Cancel.new()
    :ok = DshBeam.Agent.Cancel.cancel(token)

    assert {:error, :stopped, []} = DshBeam.Agent.Loop.run_trace(loop, "task", token)

    # the turn recorded the user message and the stop, and never reached the
    # model (the blocking adapter would otherwise have reported in)
    assert [
             %{"role" => "user", "content" => "task"},
             %{"role" => "error", "content" => "stopped by user"}
           ] = DshBeam.Session.all(session)

    refute_received {:model_entered, _}
  end

  test "cancelling mid-loop halts at the next step boundary and records the abort" do
    {:ok, runtime} =
      DshBeam.Runtime.start_link(
        [session_entry(), llm_entry(), adapter_entry(), tool_entry(), loop_entry()],
        []
      )

    %{loop: %{pid: loop}} = DshBeam.Runtime.entries(runtime)
    ctx = DshBeam.Runtime.context(runtime)
    {:ok, session} = DshBeam.Context.get(ctx, :session)

    token = DshBeam.Agent.Cancel.new()
    task = Task.async(fn -> DshBeam.Agent.Loop.run_trace(loop, "task", token) end)

    # the first model call is in-flight (the adapter blocks until released)
    assert_receive {:model_entered, adapter}, 1000

    :ok = DshBeam.Agent.Cancel.cancel(token)
    send(adapter, :release)

    assert {:error, :stopped, trace} = Task.await(task, 2000)

    # the model's tool call was skipped after cancellation: the trace records
    # the aborted dispatch, never the tool's real output
    assert trace == [
             {:tool_call, "cancel_echo", %{}},
             {:tool_result, "cancel_echo", "Error: tool call aborted before dispatch"}
           ]

    # the session is the single source of truth: user, the model's tool_call,
    # its synthetic aborted result, and the terminal stop event
    assert [
             %{"role" => "user", "content" => "task"},
             %{"role" => "tool_call", "name" => "cancel_echo"},
             %{"role" => "tool_result", "content" => "Error: tool call aborted before dispatch"},
             %{"role" => "error", "content" => "stopped by user"}
           ] = DshBeam.Session.all(session)
  end

  test "the Req adapter aborts an in-flight request when the token is cancelled" do
    test = self()

    # The plug blocks until released, standing in for a slow upstream; the
    # adapter polls the token while the request runs and brutal-kills the
    # transport on cancellation instead of waiting it out.
    plug = fn conn ->
      send(test, {:plug_entered, self()})

      receive do
        :release -> Req.Test.json(conn, %{"choices" => [%{"message" => %{"content" => "late"}}]})
      end
    end

    llm = %{
      id: :llm,
      plugin: DshBeam.Llm.Plugin,
      config: [base_url: "https://api.deepseek.com", credential: {:literal, "k"}],
      disabled: false
    }

    adapter = %{
      id: :adapter,
      plugin: DshBeam.Llm.Adapter.Req,
      config: [plug: plug],
      disabled: false
    }

    {:ok, runtime} = DshBeam.Runtime.start_link([llm, adapter], [])
    ctx = DshBeam.Runtime.context(runtime)
    {:ok, llm_pid} = DshBeam.Context.get(ctx, :llm)

    token = DshBeam.Agent.Cancel.new()

    task =
      Task.async(fn ->
        DshBeam.Llm.chat(llm_pid, [%{"role" => "user", "content" => "hi"}], cancel: token)
      end)

    assert_receive {:plug_entered, _}, 1000

    :ok = DshBeam.Agent.Cancel.cancel(token)
    assert {:error, :cancelled} = Task.await(task, 2000)

    # the transport kill never tears the adapter fiber down
    %{adapter: %{pid: adapter_pid}} = DshBeam.Runtime.entries(runtime)
    assert Process.alive?(adapter_pid)
  end

  test "the Req adapter parses a normal reply when a cancel token is present" do
    plug = fn conn ->
      Req.Test.json(conn, %{"choices" => [%{"message" => %{"content" => "parsed"}}]})
    end

    llm = %{
      id: :llm,
      plugin: DshBeam.Llm.Plugin,
      config: [base_url: "https://api.deepseek.com", credential: {:literal, "k"}],
      disabled: false
    }

    adapter = %{
      id: :adapter,
      plugin: DshBeam.Llm.Adapter.Req,
      config: [plug: plug],
      disabled: false
    }

    {:ok, runtime} = DshBeam.Runtime.start_link([llm, adapter], [])
    ctx = DshBeam.Runtime.context(runtime)
    {:ok, llm_pid} = DshBeam.Context.get(ctx, :llm)

    token = DshBeam.Agent.Cancel.new()

    assert {:ok, %{content: "parsed"}} =
             DshBeam.Llm.chat(llm_pid, [%{"role" => "user", "content" => "hi"}], cancel: token)
  end
end

defmodule CancelEchoTool do
  @moduledoc false
  use DshBeam.Plugin

  tool(:cancel_echo,
    description: "echo the input",
    parameters: %{"type" => "object", "properties" => %{"text" => %{"type" => "string"}}}
  )

  @impl DshBeam.Plugin
  def handle_dsh_tool_call(:cancel_echo, %{"text" => text}, _state), do: {:ok, "echo:" <> text}
end

defmodule CancelBlockingAdapter do
  @moduledoc false
  # Blocks on the first completion until released, so a test can cancel the
  # token while the model call is genuinely in flight.
  use DshBeam.Llm.Adapter

  @impl true
  def complete(config, _messages, _opts) do
    send(Map.get(config, :parent, self()), {:model_entered, self()})

    receive do
      :release -> :ok
    end

    {:ok,
     %{
       content: nil,
       tool_calls: [%{id: "c1", name: "cancel_echo", arguments: ~s({"text":"hi"})}],
       finish_reason: :tool_calls,
       usage: nil
     }}
  end
end
