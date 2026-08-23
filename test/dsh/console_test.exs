defmodule DshBeam.ConsoleTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint DshBeamWeb.Endpoint

  setup do
    # the seed mounts the llm provider with the real Req adapter; ensure no
    # API key leaks from the developer's environment into the chat-path tests
    previous_key = System.get_env("DEEPSEEK_API_KEY")
    System.delete_env("DEEPSEEK_API_KEY")

    on_exit(fn ->
      if previous_key, do: System.put_env("DEEPSEEK_API_KEY", previous_key)
    end)

    # start_supervised! tears the runtime down synchronously in this test's
    # teardown phase (before the next test starts), so the console's web
    # subtree (endpoint + pubsub) never overlaps the next test's mount
    runtime =
      start_supervised!(%{
        id: {:dsh_runtime, make_ref()},
        start: {DshBeam.Runtime, :start_link, [[], []]}
      })

    console_entry = %{id: :console, plugin: DshBeam.Console, config: [], disabled: false}
    :ok = DshBeam.Runtime.reconcile(runtime, [console_entry])

    ctx = DshBeam.Runtime.context(runtime)
    session = %{"runtime" => encode(runtime), "ctx" => encode(ctx)}

    %{runtime: runtime, ctx: ctx, session: session}
  end

  test "renders the composition with live fiber states and seeds the demo", %{session: session} do
    {:ok, view, html} = live(build_conn(), "/", session: session)

    assert html =~ "dsh-beam console"
    assert html =~ ":console"
    assert html =~ "DshBeam.Console"
    # the console's own fiber is active
    assert html =~ "state-active"

    html = render_submit(view, "seed", %{})
    assert html =~ ":session"
    assert html =~ ":llm"
    assert html =~ ":shell"
    assert html =~ ":bash"
    assert html =~ ":todo"
    assert html =~ ":loop"
    assert html =~ "DshBeam.Session.Plugin"
  end

  test "the todo panel renders the latest todo_write snapshot", %{session: session, ctx: ctx} do
    {:ok, view, _html} = live(build_conn(), "/", session: session)
    render_submit(view, "seed", %{})

    # before any write, the panel shows the empty state
    assert render(view) =~ "no plan yet"

    # the agent writes a whole-list snapshot; the panel projects the latest one
    {:ok, todo} = DshBeam.Context.get(ctx, :todo_write)

    assert {:ok, _} =
             DshBeam.Tool.call(todo, :todo_write, %{
               "todos" => [
                 %{"content" => "inspect the workspace", "status" => "in_progress"},
                 %{"content" => "write a summary", "status" => "pending"}
               ]
             })

    html = render(view)
    assert html =~ "inspect the workspace"
    assert html =~ "in_progress"
    assert html =~ "write a summary"
  end

  test "the chat pane reports a missing credential honestly", %{session: session} do
    {:ok, view, _html} = live(build_conn(), "/", session: session)
    render_submit(view, "seed", %{})

    # no DEEPSEEK_API_KEY -> the real Req adapter fails the credential
    # resolution, and the chat pane surfaces the error instead of a fake reply.
    # ask_ runs the loop off the LiveView process, so the error arrives as an
    # async message and is rendered afterwards.
    render_submit(view, "ask", %{"text" => "hello console"})
    wait_until(fn -> render(view) =~ "missing_env" end)
    assert render(view) =~ "missing_env"
  end

  test "the chat pane renders the loop's tool trace", %{session: session, runtime: runtime} do
    {:ok, view, _html} = live(build_conn(), "/", session: session)

    entries = [
      %{id: :session, plugin: DshBeam.Session.Plugin, config: [], disabled: false},
      %{
        id: :llm,
        plugin: DshBeam.Llm.Plugin,
        config: [adapter: ConsoleLoopLlm],
        disabled: false
      },
      %{id: :tool, plugin: ConsoleEchoTool, config: [], disabled: false},
      %{id: :loop, plugin: DshBeam.Agent.Loop, config: [], disabled: false}
    ]

    :ok = DshBeam.Runtime.reconcile(runtime, entries)

    html = render_submit(view, "ask", %{"text" => "run"})
    wait_until(fn -> render(view) =~ "final answer" end)
    html = render(view)
    assert html =~ "tool_call"
    assert html =~ "console_echo"
    assert html =~ "tool_result"
    assert html =~ "final answer"
  end

  test "the chat pane renders from the session log and clears on demand",
       %{session: session, runtime: runtime, ctx: ctx} do
    {:ok, view, _html} = live(build_conn(), "/", session: session)

    entries = [
      %{id: :session, plugin: DshBeam.Session.Plugin, config: [], disabled: false},
      %{id: :llm, plugin: DshBeam.Llm.Plugin, config: [adapter: ConsoleLoopLlm], disabled: false},
      %{id: :tool, plugin: ConsoleEchoTool, config: [], disabled: false},
      %{id: :loop, plugin: DshBeam.Agent.Loop, config: [], disabled: false}
    ]

    :ok = DshBeam.Runtime.reconcile(runtime, entries)

    render_submit(view, "ask", %{"text" => "run"})
    wait_until(fn -> render(view) =~ "final answer" end)

    # the conversation lives in the session (the single source of truth), so a
    # page refresh re-reads it: the chat pane is derived, not accumulated
    {:ok, session_pid} = DshBeam.Context.get(ctx, :session)

    assert [
             %{"role" => "user"},
             %{"role" => "tool_call"},
             %{"role" => "tool_result"},
             %{"role" => "assistant"}
           ] =
             DshBeam.Session.all(session_pid)

    # the rendered pane mirrors the session (tool call + result + answer)
    assert render(view) =~ "tool_call"
    assert render(view) =~ "final answer"

    # clear_chat truncates the session log and empties the pane
    render_click(view, "clear_chat", %{})
    assert DshBeam.Session.count(session_pid) == 0
    refute render(view) =~ "final answer"
  end

  test "the creator form defines a plugin in-process", %{session: session, ctx: ctx} do
    {:ok, view, _html} = live(build_conn(), "/", session: session)

    source = """
    defmodule FormMade do
      use DshBeam.Plugin
      provide :form_made, value: 7
    end
    """

    html = render_submit(view, "define", %{"source" => source, "mode" => "trusted"})
    assert html =~ "FormMade"
    wait_until(fn -> DshBeam.Context.get(ctx, :form_made) == {:ok, 7} end)
  end

  test "the llm settings panel reconfigures the provider without re-mounting",
       %{session: session, ctx: ctx, runtime: runtime} do
    {:ok, view, _html} = live(build_conn(), "/", session: session)
    render_submit(view, "seed", %{})

    {:ok, llm} = DshBeam.Context.get(ctx, :llm)
    %{llm: %{pid: pid_before}} = DshBeam.Runtime.entries(runtime)

    html =
      render_submit(view, "llm_apply", %{
        "base_url" => "https://example.com",
        "model" => "deepseek-reasoner",
        "credential_mode" => "env",
        "credential_value" => "MY_KEY"
      })

    assert html =~ "deepseek-reasoner"

    # dynamic reconfiguration: the fiber is untouched, the facts changed
    assert %{llm: %{pid: ^pid_before}} = DshBeam.Runtime.entries(runtime)
    assert %{model: "deepseek-reasoner", credential: {:env, "MY_KEY"}} = DshBeam.Llm.config(llm)
  end

  test "the llm settings panel stores a literal API key and keeps it on blank re-apply",
       %{session: session, ctx: ctx} do
    {:ok, view, _html} = live(build_conn(), "/", session: session)
    render_submit(view, "seed", %{})

    {:ok, llm} = DshBeam.Context.get(ctx, :llm)

    # paste a literal key, leave base_url/model blank (only the key changes)
    render_submit(view, "llm_apply", %{
      "base_url" => "https://api.deepseek.com",
      "model" => "deepseek-chat",
      "credential_mode" => "literal",
      "credential_value" => "sk-test-key"
    })

    assert %{credential: {:literal, "sk-test-key"}} = DshBeam.Llm.config(llm)

    # re-apply with a blank credential field keeps the current key
    render_submit(view, "llm_apply", %{
      "base_url" => "https://api.deepseek.com",
      "model" => "deepseek-chat",
      "credential_mode" => "literal",
      "credential_value" => ""
    })

    assert %{credential: {:literal, "sk-test-key"}} = DshBeam.Llm.config(llm)
  end

  test "the plugins panel lists the inventory and saves a setting override",
       %{session: session, runtime: runtime} do
    {:ok, view, html} = live(build_conn(), "/", session: session)

    assert html =~ "ConsoleSettingsPlugin"
    assert html =~ "enabled"

    html =
      render_submit(view, "settings_save", %{
        "plugin" => to_string(ConsoleSettingsPlugin),
        "settings" => %{"answer_limit" => "9"}
      })

    # the override persisted and re-rendered
    store = DshBeam.Runtime.settings(runtime)
    assert {:ok, 9} = DshBeam.Settings.get(store, ConsoleSettingsPlugin, :answer_limit)
    assert html =~ "9"
  end

  test "the sandbox form defines a plugin outside the host BEAM", %{session: session, ctx: ctx} do
    {:ok, view, _html} = live(build_conn(), "/", session: session)

    source = """
    defmodule SbxConsoleMade do
      def mount(_config) do
        {:ok, [], %{"console_made" => 13}, %{}}
      end
    end
    """

    html = render_submit(view, "define", %{"source" => source, "mode" => "sandbox"})
    # the row id renders HTML-escaped ("&quot;")
    assert html =~ ~s({:sandbox, &quot;)

    wait_until(fn -> DshBeam.Context.get(ctx, :console_made) == {:ok, 13} end)
    assert Code.ensure_loaded?(SbxConsoleMade) == false
  end

  test "a kill updates the view through the runtime event stream", %{session: session} do
    {:ok, view, _html} = live(build_conn(), "/", session: session)
    render_submit(view, "seed", %{})

    key = encode(:session)
    render_click(view, "kill", %{"id" => key})

    # no page reload: the runtime event stream refreshes the row
    wait_until(fn -> render(view) =~ ":killed" end)
    assert render(view) =~ "{:exited, :killed}"
  end

  test "crashing a sandbox child re-injects a fresh OS process", %{
    session: session,
    ctx: ctx,
    runtime: runtime
  } do
    {:ok, view, _html} = live(build_conn(), "/", session: session)

    source = """
    defmodule SbxConsoleCrashable do
      def mount(_config), do: {:ok, [], %{"crashable" => true}, %{}}
    end
    """

    render_submit(view, "define", %{"source" => source, "mode" => "sandbox"})
    wait_until(fn -> DshBeam.Context.get(ctx, :crashable) == {:ok, true} end)

    adapter = sandbox_adapter(runtime)
    os_pid_before = DshBeam.Sandbox.Plugin.os_pid(adapter)
    assert is_integer(os_pid_before)

    key = encode(sbx_id(runtime))
    render_click(view, "crash_child", %{"id" => key})

    wait_until(fn ->
      fresh = sandbox_adapter(runtime)
      fresh != nil and fresh != adapter and DshBeam.Sandbox.Plugin.os_pid(fresh) != os_pid_before
    end)

    assert {:ok, true} = DshBeam.Context.get(ctx, :crashable)
  end

  defp sbx_id(runtime) do
    runtime
    |> DshBeam.Runtime.entries()
    |> Enum.find_value(fn
      {{:sandbox, _} = id, _rec} -> id
      _ -> nil
    end)
  end

  defp sandbox_adapter(runtime) do
    runtime
    |> DshBeam.Runtime.entries()
    |> Enum.find_value(fn
      {{:sandbox, _}, %{pid: pid}} -> pid
      _ -> nil
    end)
  end

  defp encode(term), do: term |> :erlang.term_to_binary() |> Base.encode64()

  defp wait_until(fun), do: wait_until(fun, 400)

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

defmodule ConsoleSettingsPlugin do
  @moduledoc false
  use DshBeam.Plugin

  setting(:answer_limit, type: :integer, default: 3, doc: "max answers per request")
end

defmodule ConsoleEchoTool do
  @moduledoc false
  use DshBeam.Plugin

  tool(:console_echo,
    description: "echo the input",
    parameters: %{"type" => "object", "properties" => %{"text" => %{"type" => "string"}}}
  )

  @impl DshBeam.Plugin
  def handle_dsh_tool_call(:console_echo, %{"text" => text}, _state), do: {:ok, "echo:" <> text}
end

defmodule ConsoleLoopLlm do
  @moduledoc false
  @behaviour DshBeam.Llm.Adapter

  @impl true
  def complete(_config, messages, _opts) do
    if Enum.any?(messages, &(&1["role"] == "tool")) do
      {:ok, %{content: "final answer", tool_calls: [], finish_reason: :stop}}
    else
      {:ok,
       %{
         content: nil,
         tool_calls: [%{id: "c1", name: "console_echo", arguments: ~s({"text":"hi"})}],
         finish_reason: :tool_calls
       }}
    end
  end
end
