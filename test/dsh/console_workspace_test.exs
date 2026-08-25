defmodule DshBeam.ConsoleWorkspaceTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint DshBeamWeb.Endpoint

  setup do
    dir = Path.join(System.tmp_dir!(), "dsh_cws_repo_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    run_git(dir, ["init", "-q", "-b", "main"])
    File.write!(Path.join(dir, "README.md"), "hello")
    run_git(dir, ["add", "."])
    run_git(dir, ["commit", "-q", "-m", "init"])
    on_exit(fn -> File.rm_rf!(dir) end)

    runtime =
      start_supervised!(%{
        id: {:dsh_runtime, make_ref()},
        start: {DshBeam.Runtime, :start_link, [[], []]}
      })

    entries = [
      %{id: :console, plugin: DshBeam.Console, config: [], disabled: false},
      %{id: :session, plugin: DshBeam.Session.Plugin, config: [], disabled: false},
      %{id: :workspace, plugin: DshBeam.Workspace, config: [], disabled: false}
    ]

    :ok = DshBeam.Runtime.reconcile(runtime, entries)
    ctx = DshBeam.Runtime.context(runtime)
    session = %{"runtime" => encode(runtime), "ctx" => encode(ctx)}

    %{runtime: runtime, ctx: ctx, session: session, repo: dir}
  end

  test "the workspace panel lists sessions and creates one over a repo", %{
    session: session,
    ctx: ctx,
    repo: repo
  } do
    {:ok, view, _html} = live(build_conn(), "/", session: session)

    # empty state before any session exists
    assert render(view) =~ "no sessions"

    render_submit(view, "workspace_create", %{"repo" => repo, "title" => "task one"})
    html = render(view)

    assert html =~ "task one"
    assert html =~ "idle"

    {:ok, workspace} = DshBeam.Context.get(ctx, :workspace)
    assert map_size(DshBeam.Workspace.all_sessions(workspace)) == 1
  end

  test "switching a session rebinds :session to the workspace session", %{
    session: session,
    ctx: ctx,
    repo: repo
  } do
    {:ok, view, _html} = live(build_conn(), "/", session: session)

    render_submit(view, "workspace_create", %{"repo" => repo, "title" => "task two"})

    {:ok, workspace} = DshBeam.Context.get(ctx, :workspace)
    [workspace_session] = Map.keys(DshBeam.Workspace.all_sessions(workspace))
    key = encode(workspace_session)

    # the mount-default session is not a workspace session
    {:ok, before} = DshBeam.Context.get(ctx, :session)
    refute before == workspace_session

    render_click(view, "workspace_switch", %{"session" => key})

    wait_until(fn -> DshBeam.Context.get(ctx, :session) == {:ok, workspace_session} end)
    assert render(view) =~ "current"
  end

  test "the trajectory panel groups the session log into turns", %{
    session: session,
    ctx: ctx,
    repo: repo
  } do
    {:ok, view, _html} = live(build_conn(), "/", session: session)

    # chat/trajectory render only under a workspace session
    render_submit(view, "workspace_create", %{"repo" => repo, "title" => "trajectory"})
    {:ok, workspace} = DshBeam.Context.get(ctx, :workspace)
    [ws] = Map.keys(DshBeam.Workspace.all_sessions(workspace))
    render_click(view, "workspace_switch", %{"session" => encode(ws)})
    wait_until(fn -> DshBeam.Context.get(ctx, :session) == {:ok, ws} end)

    {:ok, session_pid} = DshBeam.Context.get(ctx, :session)

    DshBeam.Session.append(session_pid, %{"role" => "user", "content" => "hello"})

    DshBeam.Session.append(session_pid, %{
      "role" => "tool_call",
      "name" => "echo",
      "arguments" => %{}
    })

    DshBeam.Session.append(session_pid, %{"role" => "assistant", "content" => "hi back"})

    DshBeam.Session.append(session_pid, %{"role" => "user", "content" => "again"})
    DshBeam.Session.append(session_pid, %{"role" => "assistant", "content" => "ok"})

    _ = open_tab(view, "trajectory")
    html = render(view)
    assert html =~ "turn 1"
    assert html =~ "turn 2"
    assert html =~ "hello"
    assert html =~ "hi back"
    assert html =~ "again"
    assert html =~ "ok"
  end

  test "end-to-end: workspace → session → chat task → trajectory → settings", %{
    session: session,
    ctx: ctx,
    runtime: runtime,
    repo: repo
  } do
    {:ok, view, _html} = live(build_conn(), "/", session: session)

    # 1. workspace: create a worktree session and switch to it
    render_submit(view, "workspace_create", %{"repo" => repo, "title" => "e2e task"})
    {:ok, workspace} = DshBeam.Context.get(ctx, :workspace)
    [ws_session] = Map.keys(DshBeam.Workspace.all_sessions(workspace))
    render_click(view, "workspace_switch", %{"session" => encode(ws_session)})
    wait_until(fn -> DshBeam.Context.get(ctx, :session) == {:ok, ws_session} end)

    # 2. mount the agent composition over the workspace session
    entries = [
      %{id: :console, plugin: DshBeam.Console, config: [], disabled: false},
      %{
        id: :session,
        plugin: DshBeam.Session.Plugin,
        config: [session: ws_session],
        disabled: false
      },
      %{id: :workspace, plugin: DshBeam.Workspace, config: [], disabled: false},
      %{id: :llm, plugin: DshBeam.Llm.Plugin, config: [], disabled: false},
      %{id: :adapter, plugin: CwsLlm, config: [], disabled: false},
      %{id: :tool, plugin: CwsEchoTool, config: [], disabled: false},
      %{id: :loop, plugin: DshBeam.Agent.Loop, config: [], disabled: false}
    ]

    :ok = DshBeam.Runtime.reconcile(runtime, entries)

    # 3. chat task: drive the loop through the scripted model
    render_submit(view, "ask", %{"text" => "do the thing"})
    wait_until(fn -> render(view) =~ "final answer" end)
    _ = open_tab(view, "trajectory")

    # 4. trajectory: the turn is grouped and visible
    html = render(view)
    assert html =~ "turn 1"
    assert html =~ "do the thing"
    assert html =~ "cws_echo"
    assert html =~ "final answer"

    # the whole turn is recorded in the *workspace* session (the switched one);
    # structural events (turn_start/request/turn_end) wrap the content
    roles =
      ws_session
      |> DshBeam.Session.all()
      |> Enum.reject(&(&1["role"] in ["turn_start", "turn_end", "request"]))
      |> Enum.map(& &1["role"])

    assert roles == ["user", "tool_call", "tool_result", "assistant"]

    # 5. settings: a typed setting save persists to the store and re-mounts
    render_submit(view, "settings_save", %{
      "plugin" => to_string(DshBeam.Agent.Loop),
      "settings" => %{"max_steps" => "7"}
    })

    store = DshBeam.Runtime.settings(runtime)
    assert {:ok, 7} = DshBeam.Settings.get(store, DshBeam.Agent.Loop, :max_steps)
  end

  defp encode(term), do: term |> :erlang.term_to_binary() |> Base.encode64()

  defp open_tab(view, tab), do: render_click(view, "view_tab", %{"tab" => tab})

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

  defp run_git(dir, args) do
    # CI runners have no git identity; supply one for every command (commit
    # needs it, and it is harmless for init/add/config).
    git = ["-c", "user.name=CI", "-c", "user.email=ci@example.com" | args]
    {_out, 0} = System.cmd("git", git, stderr_to_stdout: true, cd: dir)
    :ok
  end
end

defmodule CwsEchoTool do
  @moduledoc false
  use DshBeam.Plugin

  tool(:cws_echo,
    description: "echo the input",
    parameters: %{"type" => "object", "properties" => %{"text" => %{"type" => "string"}}}
  )

  @impl DshBeam.Plugin
  def handle_dsh_tool_call(:cws_echo, %{"text" => text}, _state), do: {:ok, "echo:" <> text}
end

defmodule CwsLlm do
  @moduledoc false
  use DshBeam.Llm.Adapter

  @impl true
  def complete(_config, messages, _opts) do
    if Enum.any?(messages, &(&1["role"] == "tool")) do
      {:ok, %{content: "final answer", tool_calls: [], finish_reason: :stop, usage: nil}}
    else
      {:ok,
       %{
         content: nil,
         tool_calls: [%{id: "c1", name: "cws_echo", arguments: ~s({"text":"hi"})}],
         finish_reason: :tool_calls,
         usage: nil
       }}
    end
  end
end
