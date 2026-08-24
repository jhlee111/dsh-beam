defmodule DshBeam.LlmTest do
  use ExUnit.Case, async: false

  defp llm_entry(opts) do
    %{id: :llm, plugin: DshBeam.Llm.Plugin, config: opts, disabled: false}
  end

  defp adapter_entry(module, config \\ []) do
    %{id: :adapter, plugin: module, config: config, disabled: false}
  end

  defp session_entry do
    %{id: :session, plugin: DshBeam.Session.Plugin, config: [], disabled: false}
  end

  defp chat_entry do
    %{id: :chat, plugin: DshBeam.Llm.Chat, config: [], disabled: false}
  end

  test "the llm plugin provides :llm and completes through the mounted adapter" do
    config = [model: "stub-model", adapter_config: %{parent: self()}]

    {:ok, runtime} =
      DshBeam.Runtime.start_link(
        [llm_entry(config), adapter_entry(StubLlmAdapter, parent: self())],
        []
      )

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
    llm = llm_entry(model: "stub-model", adapter_config: %{parent: self()})

    {:ok, runtime} =
      DshBeam.Runtime.start_link(
        [session_entry(), llm, adapter_entry(StubLlmAdapter, parent: self()), chat_entry()],
        []
      )

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

  test "the chat consumer replays a tool turn through the projection" do
    llm = llm_entry(model: "stub-model", adapter_config: %{parent: self()})

    {:ok, runtime} =
      DshBeam.Runtime.start_link(
        [session_entry(), llm, adapter_entry(StubLlmAdapter, parent: self()), chat_entry()],
        []
      )

    ctx = DshBeam.Runtime.context(runtime)
    wait_until(fn -> match?({:ok, _}, DshBeam.Context.get(ctx, :session)) end)

    {:ok, session} = DshBeam.Context.get(ctx, :session)
    {:ok, chat} = DshBeam.Context.get(ctx, :chat)

    # seed the log with a tool turn exactly as the agent loop records it
    # (tool_call + tool_result chronologically, then the assistant answer)
    DshBeam.Session.append(session, %{"role" => "user", "content" => "first"})

    DshBeam.Session.append(session, %{
      "role" => "tool_call",
      "id" => "c1",
      "name" => "loop_echo",
      "arguments" => %{"text" => "hi"},
      "arguments_json" => ~s({"text":"hi"})
    })

    DshBeam.Session.append(session, %{
      "role" => "tool_result",
      "tool_call_id" => "c1",
      "name" => "loop_echo",
      "content" => "echo:hi"
    })

    DshBeam.Session.append(session, %{"role" => "assistant", "content" => "done"})

    # the next chat completion must see the FULL prefix — including the tool
    # turn — replayed verbatim (cache-friendly, like the agent loop), not a
    # role/content-only mapping that drops tool_call/tool_result and shifts
    # the prompt prefix between the last tool run and the next user turn.
    assert {:ok, %{content: "stub reply: next"}} = DshBeam.Llm.Chat.ask(chat, "next")
    assert_receive {:complete, _, messages}, 1000

    assert messages == [
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
             %{"role" => "assistant", "content" => "done"},
             %{"role" => "user", "content" => "next"}
           ]

    # the projection left the append-only log untouched: the chat consumer
    # only appended its own user + assistant turns
    assert DshBeam.Session.count(session) == 6
  end

  test "removing the llm provider deactivates the chat consumer first" do
    llm = llm_entry(model: "stub-model", adapter_config: %{parent: self()})

    {:ok, runtime} =
      DshBeam.Runtime.start_link(
        [session_entry(), llm, adapter_entry(StubLlmAdapter, parent: self()), chat_entry()],
        []
      )

    ctx = DshBeam.Runtime.context(runtime)
    wait_until(fn -> match?({:ok, _}, DshBeam.Context.get(ctx, :chat)) end)
    {:ok, chat} = DshBeam.Context.get(ctx, :chat)

    # keep the adapter mounted; remove only the llm provider
    :ok =
      DshBeam.Runtime.reconcile(runtime, [
        session_entry(),
        adapter_entry(StubLlmAdapter, parent: self()),
        chat_entry()
      ])

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
      model: "deepseek-chat"
    ]

    {:ok, runtime} =
      DshBeam.Runtime.start_link(
        [llm_entry(config), adapter_entry(DshBeam.Llm.Adapter.Req, plug: plug)],
        []
      )

    ctx = DshBeam.Runtime.context(runtime)

    {:ok, llm} = DshBeam.Context.get(ctx, :llm)
    assert {:ok, "from-plug"} = DshBeam.Llm.chat(llm, [%{"role" => "user", "content" => "hi"}])

    # the credential reference was resolved into a bearer header per request
    assert_receive {:auth, headers}, 1000
    assert {"authorization", "Bearer test-key"} in headers
  end

  test "the Req adapter maps DeepSeek cache usage to disjoint counts" do
    # DeepSeek's prompt_tokens INCLUDES cache hits; the adapter must subtract
    # them so inputTokens + cacheReadTokens is the billed prompt (ADR-0014).
    plug = fn conn ->
      Req.Test.json(conn, %{
        "choices" => [%{"message" => %{"content" => "hi"}}],
        "usage" => %{
          "prompt_tokens" => 1000,
          "prompt_cache_hit_tokens" => 800,
          "prompt_cache_miss_tokens" => 200,
          "completion_tokens" => 50,
          "completion_tokens_details" => %{"reasoning_tokens" => 10}
        }
      })
    end

    config = [
      base_url: "https://api.deepseek.com",
      credential: {:literal, "test-key"},
      model: "deepseek-chat"
    ]

    {:ok, runtime} =
      DshBeam.Runtime.start_link(
        [llm_entry(config), adapter_entry(DshBeam.Llm.Adapter.Req, plug: plug)],
        []
      )

    ctx = DshBeam.Runtime.context(runtime)
    {:ok, llm} = DshBeam.Context.get(ctx, :llm)

    assert {:ok, %{usage: usage}} =
             DshBeam.Llm.chat(llm, [%{"role" => "user", "content" => "hi"}], [])

    assert usage.input_tokens == 200
    assert usage.cache_read_tokens == 800
    assert usage.cache_write_tokens == 200
    assert usage.output_tokens == 50
    assert usage.reasoning_tokens == 10
  end

  test "the Req adapter forwards tools without crashing on the keyword opts" do
    # regression: chat/3 passes opts as a keyword list [tools: ...]; the adapter
    # must read it with opts[:tools], not the map-only opts.tools (BadMapError).
    test = self()

    plug = fn conn ->
      send(test, {:body, conn.body_params})
      Req.Test.json(conn, %{"choices" => [%{"message" => %{"content" => "with-tools"}}]})
    end

    config = [
      base_url: "https://api.deepseek.com",
      credential: {:literal, "test-key"},
      model: "deepseek-chat"
    ]

    {:ok, runtime} =
      DshBeam.Runtime.start_link(
        [llm_entry(config), adapter_entry(DshBeam.Llm.Adapter.Req, plug: plug)],
        []
      )

    ctx = DshBeam.Runtime.context(runtime)

    {:ok, llm} = DshBeam.Context.get(ctx, :llm)
    tools = [%{"type" => "function", "function" => %{"name" => "bash"}}]

    assert {:ok, %{content: "with-tools"}} =
             DshBeam.Llm.chat(llm, [%{"role" => "user", "content" => "hi"}], tools: tools)

    # the tools list made it into the outgoing JSON body
    assert_receive {:body, %{"tools" => ^tools}}, 1000
  end

  test "receive_timeout is a typed llm setting that reaches the adapter config" do
    settings = DshBeam.Plugin.settings(DshBeam.Llm.Plugin)

    assert Enum.any?(
             settings,
             &(&1.name == :receive_timeout and &1.type == :integer and &1.default == 300_000)
           )

    config = [
      model: "stub-model",
      receive_timeout: 300_000,
      adapter_config: %{parent: self()}
    ]

    {:ok, runtime} =
      DshBeam.Runtime.start_link(
        [llm_entry(config), adapter_entry(StubLlmAdapter, parent: self())],
        []
      )

    ctx = DshBeam.Runtime.context(runtime)
    {:ok, llm} = DshBeam.Context.get(ctx, :llm)

    # the provider's own config carries the budget…
    assert %{receive_timeout: 300_000} = DshBeam.Llm.config(llm)

    # …and it rides the flattened adapter config into the transport call
    assert {:ok, _} = DshBeam.Llm.chat(llm, [%{"role" => "user", "content" => "hi"}])
    assert_receive {:complete_config, cfg}, 1000
    assert cfg.receive_timeout == 300_000
  end

  test "configure/2 re-arms receive_timeout without re-mounting" do
    {:ok, runtime} =
      DshBeam.Runtime.start_link(
        [
          llm_entry(model: "stub-model", adapter_config: %{parent: self()}),
          adapter_entry(StubLlmAdapter, parent: self())
        ],
        []
      )

    ctx = DshBeam.Runtime.context(runtime)
    {:ok, llm} = DshBeam.Context.get(ctx, :llm)
    %{llm: %{pid: pid_before}} = DshBeam.Runtime.entries(runtime)

    assert :ok = DshBeam.Llm.configure(llm, receive_timeout: 250_000)

    # dynamic reconfiguration: the fiber is untouched, the budget changed
    assert %{llm: %{pid: ^pid_before}} = DshBeam.Runtime.entries(runtime)
    assert %{receive_timeout: 250_000} = DshBeam.Llm.config(llm)
  end

  test "a saved receive_timeout override reaches the provider config on restart" do
    {:ok, runtime} = DshBeam.Runtime.start_link([], [])
    store = DshBeam.Runtime.settings(runtime)

    :ok =
      DshBeam.Runtime.reconcile(runtime, [
        llm_entry(model: "stub-model", adapter_config: %{parent: self()}),
        adapter_entry(StubLlmAdapter, parent: self())
      ])

    :ok = DshBeam.Settings.put(store, DshBeam.Llm.Plugin, :receive_timeout, 999_000)
    :ok = DshBeam.Runtime.restart(runtime, :llm)

    ctx = DshBeam.Runtime.context(runtime)
    {:ok, llm} = DshBeam.Context.get(ctx, :llm)
    assert %{receive_timeout: 999_000} = DshBeam.Llm.config(llm)
  end

  test "configure/2 changes connection facts for the next request without re-mounting" do
    config = [model: "stub-model", adapter_config: %{parent: self()}]

    {:ok, runtime} =
      DshBeam.Runtime.start_link(
        [llm_entry(config), adapter_entry(StubLlmAdapter, parent: self())],
        []
      )

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
      credential: {:env, "DSH_LLM_DEFINITELY_MISSING"}
    ]

    {:ok, runtime} =
      DshBeam.Runtime.start_link(
        [llm_entry(config), adapter_entry(DshBeam.Llm.Adapter.Req, plug: plug)],
        []
      )

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
  use DshBeam.Llm.Adapter

  @impl true
  def complete(config, messages, _opts) do
    parent = Map.get(config, :parent, self())
    send(parent, {:complete, config.model, messages})
    send(parent, {:complete_config, config})

    {:ok,
     %{
       content: "stub reply: " <> List.last(messages)["content"],
       tool_calls: [],
       finish_reason: :stop,
       usage: nil
     }}
  end
end
