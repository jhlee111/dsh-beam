defmodule DshBeam.ConsoleTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint DshBeamWeb.Endpoint

  setup do
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
    assert html =~ ":chat"
    assert html =~ "DshBeam.Llm.Chat"
    assert html =~ "DshBeam.Session.Plugin"
  end

  test "the chat pane runs the full loop through session + llm plugins", %{
    session: session,
    ctx: ctx
  } do
    {:ok, view, _html} = live(build_conn(), "/", session: session)
    render_submit(view, "seed", %{})

    html = render_submit(view, "ask", %{"text" => "hello console"})
    assert html =~ "echo: hello console"

    {:ok, session_pid} = DshBeam.Context.get(ctx, :session)
    assert DshBeam.Session.count(session_pid) == 2
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
