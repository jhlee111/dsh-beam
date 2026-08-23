defmodule DshBeam.WorkspaceTest do
  use ExUnit.Case, async: false

  defp workspace_entry do
    %{id: :workspace, plugin: DshBeam.Workspace, config: [], disabled: false}
  end

  test "sessions in the same cwd see each other as peers" do
    {:ok, runtime} = DshBeam.Runtime.start_link([workspace_entry()], [])
    ctx = DshBeam.Runtime.context(runtime)
    {:ok, workspace} = DshBeam.Context.get(ctx, :workspace)

    {:ok, session_a} = DshBeam.Session.Memory.start_link(title: "A", cwd: "/repo")
    {:ok, session_b} = DshBeam.Session.Memory.start_link(title: "B", cwd: "/repo")
    {:ok, session_c} = DshBeam.Session.Memory.start_link(title: "C", cwd: "/other")

    :ok = DshBeam.Workspace.register(workspace, session_a, "/repo")
    :ok = DshBeam.Workspace.register(workspace, session_b, "/repo")
    :ok = DshBeam.Workspace.register(workspace, session_c, "/other")

    # A and B share /repo; C is elsewhere
    {:ok, a_peers} = DshBeam.Workspace.peers(workspace, session_a)
    assert session_b in a_peers
    refute session_a in a_peers
    refute session_c in a_peers
  end

  test "relay appends a peer message to the target session's log" do
    {:ok, runtime} = DshBeam.Runtime.start_link([workspace_entry()], [])
    ctx = DshBeam.Runtime.context(runtime)
    {:ok, workspace} = DshBeam.Context.get(ctx, :workspace)

    {:ok, session_a} = DshBeam.Session.Memory.start_link(title: "A", cwd: "/repo")
    {:ok, session_b} = DshBeam.Session.Memory.start_link(title: "B", cwd: "/repo")

    :ok = DshBeam.Workspace.register(workspace, session_a, "/repo")
    :ok = DshBeam.Workspace.register(workspace, session_b, "/repo")

    assert {:ok, _} = DshBeam.Workspace.relay(workspace, session_a, session_b, "please help")

    # the peer message landed in B's log
    assert [%{"role" => "peer_message", "from" => _, "content" => "please help"}] =
             DshBeam.Session.all(session_b)
  end

  test "relay refuses sessions in different workspaces" do
    {:ok, runtime} = DshBeam.Runtime.start_link([workspace_entry()], [])
    ctx = DshBeam.Runtime.context(runtime)
    {:ok, workspace} = DshBeam.Context.get(ctx, :workspace)

    {:ok, session_a} = DshBeam.Session.Memory.start_link(title: "A", cwd: "/repo")
    {:ok, session_c} = DshBeam.Session.Memory.start_link(title: "C", cwd: "/other")

    :ok = DshBeam.Workspace.register(workspace, session_a, "/repo")
    :ok = DshBeam.Workspace.register(workspace, session_c, "/other")

    assert {:error, :different_workspace} =
             DshBeam.Workspace.relay(workspace, session_a, session_c, "hi")

    assert DshBeam.Session.all(session_c) == []
  end

  test "a session header carries its title and cwd" do
    {:ok, session} = DshBeam.Session.Memory.start_link(title: "my task", cwd: "/repo")
    assert DshBeam.Session.header(session) == %{title: "my task", cwd: "/repo"}

    :ok = DshBeam.Session.set_header(session, %{cwd: "/repo/new"})
    assert DshBeam.Session.header(session).cwd == "/repo/new"
  end

  # -- worktree-backed sessions (the workspace owns the checkout) --

  setup :git_repo

  defp git_repo(_context) do
    dir = Path.join(System.tmp_dir!(), "dsh_ws_repo_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    run_git(dir, ["init", "-q", "-b", "main"])
    File.write!(Path.join(dir, "README.md"), "hello")
    run_git(dir, ["add", "."])
    run_git(dir, ["commit", "-q", "-m", "init"])

    on_exit(fn -> File.rm_rf!(dir) end)
    %{repo: dir}
  end

  test "open_session checks out a worktree and starts the session log in it", %{repo: repo} do
    {:ok, runtime} = DshBeam.Runtime.start_link([workspace_entry()], [])
    ctx = DshBeam.Runtime.context(runtime)
    {:ok, workspace} = DshBeam.Context.get(ctx, :workspace)

    assert {:ok, session} = DshBeam.Workspace.open_session(workspace, repo)

    # the session owns its checkout: header.cwd is the worktree, which exists
    # on disk with the repository's content checked out
    %{cwd: cwd, title: title} = DshBeam.Session.header(session)
    assert is_binary(cwd)
    assert File.exists?(Path.join(cwd, "README.md"))
    assert title =~ "session/"

    # and the workspace lists it
    assert %{^session => %{repo: _}} = DshBeam.Workspace.all_sessions(workspace)
  end

  test "two sessions over one repository get distinct worktrees", %{repo: repo} do
    {:ok, runtime} = DshBeam.Runtime.start_link([workspace_entry()], [])
    ctx = DshBeam.Runtime.context(runtime)
    {:ok, workspace} = DshBeam.Context.get(ctx, :workspace)

    {:ok, a} = DshBeam.Workspace.open_session(workspace, repo)
    {:ok, b} = DshBeam.Workspace.open_session(workspace, repo)

    %{cwd: cwd_a} = DshBeam.Session.header(a)
    %{cwd: cwd_b} = DshBeam.Session.header(b)
    assert cwd_a != cwd_b

    # a write in one worktree does not appear in the other (isolation)
    File.write!(Path.join(cwd_a, "only_a.txt"), "a")
    refute File.exists?(Path.join(cwd_b, "only_a.txt"))

    assert map_size(DshBeam.Workspace.all_sessions(workspace)) == 2
  end

  test "close_session removes the worktree and drops the session", %{repo: repo} do
    {:ok, runtime} = DshBeam.Runtime.start_link([workspace_entry()], [])
    ctx = DshBeam.Runtime.context(runtime)
    {:ok, workspace} = DshBeam.Context.get(ctx, :workspace)

    {:ok, session} = DshBeam.Workspace.open_session(workspace, repo)
    %{cwd: cwd} = DshBeam.Session.header(session)
    assert File.exists?(cwd)

    assert :ok = DshBeam.Workspace.close_session(workspace, session)

    refute File.exists?(cwd)
    assert DshBeam.Workspace.all_sessions(workspace) == %{}
    refute Process.alive?(session)
  end

  test "open_session outside a repository opens an in-place session", _context do
    {:ok, runtime} = DshBeam.Runtime.start_link([workspace_entry()], [])
    ctx = DshBeam.Runtime.context(runtime)
    {:ok, workspace} = DshBeam.Context.get(ctx, :workspace)

    outside = Path.join(System.tmp_dir!(), "dsh_ws_notrepo_#{System.unique_integer([:positive])}")
    File.mkdir_p!(outside)
    on_exit(fn -> File.rm_rf!(outside) end)

    # a non-repo folder opens in-place (no worktree) rather than refusing
    assert {:ok, session} = DshBeam.Workspace.open_session(workspace, outside)

    assert %{^session => %{cwd: ^outside, repo: nil}} =
             DshBeam.Workspace.all_sessions(workspace)

    # closing an in-place session does not try to remove a worktree
    assert :ok = DshBeam.Workspace.close_session(workspace, session)
    assert DshBeam.Workspace.all_sessions(workspace) == %{}
  end

  defp run_git(dir, args) do
    {_out, 0} = System.cmd("git", args, stderr_to_stdout: true, cd: dir)
    :ok
  end
end
