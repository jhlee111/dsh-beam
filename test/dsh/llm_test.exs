defmodule DshBeam.LlmTest do
  use ExUnit.Case, async: false

  defp llm_entry(opts) do
    %{id: :llm, plugin: DshBeam.Llm.Plugin, config: opts, disabled: false}
  end

  defp session_entry do
    %{id: :session, plugin: DshBeam.Session.Plugin, config: [], disabled: false}
  end

  defp chat_entry do
    %{id: :chat, plugin: DshBeam.Llm.Chat, config: [], disabled: false}
  end

  test "the llm plugin provides :llm and completes through the configured adapter" do
    config = [adapter: StubLlmAdapter, model: "stub-model", adapter_config: %{parent: self()}]
    {:ok, runtime} = DshBeam.Runtime.start_link([llm_entry(config)], [])
    ctx = DshBeam.Runtime.context(runtime)

    assert {:ok, llm} = DshBeam.Context.get(ctx, :llm)

    messages = [
      %{"role" => "system", "content" => "be terse"},
      %{"role" => "user", "content" => "hi"}
    ]

    assert {:ok, "stub reply: hi"} = DshBeam.Llm.chat(llm, messages)

    # the adapter saw the resolved config and the full message list
    assert_receive {:complete, "stub-model", ^messages}, 1000
  end

  test "the chat consumer appends user and assistant turns to the session" do
    llm = llm_entry(adapter: StubLlmAdapter, adapter_config: %{parent: self()})

    {:ok, runtime} =
      DshBeam.Runtime.start_link([session_entry(), llm, chat_entry()], [])

    ctx = DshBeam.Runtime.context(runtime)

    wait_until(fn -> match?({:ok, _}, DshBeam.Context.get(ctx, :session)) end)

    {:ok, session} = DshBeam.Context.get(ctx, :session)
    {:ok, chat} = DshBeam.Context.get(ctx, :chat)

    # the chat plugin resolves both declarations
    %{fibers: fibers} = DshBeam.Context.snapshot(ctx)
    assert %{^chat => %{state: :active}} = fibers

    assert {:ok, %{content: "stub reply: hello", user_seq: 1}} =
             DshBeam.Llm.Chat.ask(chat, "hello")

    # the first completion saw only the user turn
    assert_receive {:complete, _, [%{"content" => "hello"}]}, 1000

    assert DshBeam.Session.count(session) == 2
    assert events = DshBeam.Session.all(session)

    assert [
             %{"role" => "user", "content" => "hello"},
             %{"role" => "assistant", "content" => "stub reply: hello"}
           ] = events

    # a second turn carries the full history into the model
    assert {:ok, _} = DshBeam.Llm.Chat.ask(chat, "again")
    assert_receive {:complete, _, history}, 1000
    assert length(history) == 3
  end

  test "removing the llm provider deactivates the chat consumer first" do
    llm = llm_entry(adapter: StubLlmAdapter, adapter_config: %{parent: self()})

    {:ok, runtime} =
      DshBeam.Runtime.start_link([session_entry(), llm, chat_entry()], [])

    ctx = DshBeam.Runtime.context(runtime)
    wait_until(fn -> match?({:ok, _}, DshBeam.Context.get(ctx, :chat)) end)
    {:ok, chat} = DshBeam.Context.get(ctx, :chat)

    :ok = DshBeam.Runtime.reconcile(runtime, [session_entry(), chat_entry()])

    history = DshBeam.Context.history(ctx)
    deactivated = Enum.find_index(history, &match?({:deactivated, pid} when pid == chat, &1))
    unloaded = Enum.find_index(history, &match?({:unloaded, _pid}, &1))
    assert deactivated != nil and unloaded != nil and deactivated < unloaded

    assert DshBeam.Context.get(ctx, :llm) == :not_found
    assert DshBeam.Plugin.fiber_state(chat) == :inactive
    assert {:error, :capabilities_unavailable} = DshBeam.Llm.Chat.ask(chat, "hello?")
  end

  test "the Req adapter resolves the credential and parses the completion" do
    # the transport itself is the mock boundary: a plug replaces the network
    test = self()

    plug = fn conn ->
      send(test, {:auth, conn.req_headers})
      Req.Test.json(conn, %{"choices" => [%{"message" => %{"content" => "from-plug"}}]})
    end

    config = [
      base_url: "https://api.deepseek.com",
      credential: {:literal, "test-key"},
      model: "deepseek-chat",
      adapter_config: %{plug: plug}
    ]

    {:ok, runtime} = DshBeam.Runtime.start_link([llm_entry(config)], [])
    ctx = DshBeam.Runtime.context(runtime)

    {:ok, llm} = DshBeam.Context.get(ctx, :llm)
    assert {:ok, "from-plug"} = DshBeam.Llm.chat(llm, [%{"role" => "user", "content" => "hi"}])

    # the credential reference was resolved into a bearer header per request
    assert_receive {:auth, headers}, 1000
    assert {"authorization", "Bearer test-key"} in headers
  end

  test "configure/2 changes connection facts for the next request without re-mounting" do
    config = [adapter: StubLlmAdapter, model: "stub-model", adapter_config: %{parent: self()}]
    {:ok, runtime} = DshBeam.Runtime.start_link([llm_entry(config)], [])
    ctx = DshBeam.Runtime.context(runtime)

    {:ok, llm} = DshBeam.Context.get(ctx, :llm)
    %{llm: %{pid: pid_before}} = DshBeam.Runtime.entries(runtime)

    assert :ok = DshBeam.Llm.configure(llm, model: "new-model")

    # the fiber was not re-mounted — only its connection facts changed
    assert %{llm: %{pid: ^pid_before}} = DshBeam.Runtime.entries(runtime)

    assert {:ok, _} = DshBeam.Llm.chat(llm, [%{"role" => "user", "content" => "hi"}])
    assert_receive {:complete, "new-model", _}, 1000

    assert %{model: "new-model"} = DshBeam.Llm.config(llm)
  end

  test "a missing credential fails the completion before any request" do
    plug = fn conn ->
      send(self(), :request_made)
      Req.Test.json(conn, %{})
    end

    config = [
      credential: {:env, "DSH_LLM_DEFINITELY_MISSING"},
      adapter_config: %{plug: plug}
    ]

    {:ok, runtime} = DshBeam.Runtime.start_link([llm_entry(config)], [])
    ctx = DshBeam.Runtime.context(runtime)

    {:ok, llm} = DshBeam.Context.get(ctx, :llm)

    assert {:error, {:missing_env, "DSH_LLM_DEFINITELY_MISSING"}} =
             DshBeam.Llm.chat(llm, [%{"role" => "user", "content" => "hi"}])

    refute_received :request_made
  end

  defp wait_until(fun), do: wait_until(fun, 200)

  defp wait_until(fun, tries) when is_function(fun, 0) do
    cond do
      fun.() ->
        :ok

      tries <= 0 ->
        raise "condition not reached"

      true ->
        Process.sleep(10)
        wait_until(fun, tries - 1)
    end
  end
end

defmodule StubLlmAdapter do
  @moduledoc false
  @behaviour DshBeam.Llm.Adapter

  @impl true
  def complete(config, messages) do
    parent = Map.get(config, :parent, self())
    send(parent, {:complete, config.model, messages})
    {:ok, "stub reply: " <> List.last(messages)["content"]}
  end
end
