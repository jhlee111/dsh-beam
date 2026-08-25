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
    # the default title is the workspace folder name, not the internal branch
    assert title =~ "dsh_ws_repo"

    # a worktree-backed session pins itself with a live marker (boot-GC fence)
    assert File.exists?(Path.join([cwd, ".dsh", "live"]))

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
    assert File.exists?(Path.join([cwd, ".dsh", "live"]))

    assert :ok = DshBeam.Workspace.close_session(workspace, session)

    refute File.exists?(cwd)
    assert DshBeam.Workspace.all_sessions(workspace) == %{}
    refute Process.alive?(session)
  end

  test "workspace mount does not prune without boot_prune: true", %{repo: repo} do
    # a merged, old, clean session worktree — the exact shape the old boot GC
    # would have deleted
    dest = worktree_session(repo, "session/oldmerged")
    age!(dest)

    # default config (no boot_prune): mounting the workspace must not touch it
    {:ok, runtime} = DshBeam.Runtime.start_link([workspace_entry()], [])
    ctx = DshBeam.Runtime.context(runtime)
    {:ok, workspace} = DshBeam.Context.get(ctx, :workspace)
    assert is_pid(workspace)

    assert File.exists?(dest)
  end

  test "a roster_path persists sessions and restores them on remount", %{repo: repo} do
    roster_path =
      Path.join(System.tmp_dir!(), "dsh_roster_#{System.unique_integer([:positive])}.json")

    on_exit(fn -> File.rm_rf!(roster_path) end)

    entry = %{
      id: :workspace,
      plugin: DshBeam.Workspace,
      config: [roster_path: roster_path],
      disabled: false
    }

    # first mount: open a session, append a durable event
    {:ok, runtime1} = DshBeam.Runtime.start_link([entry], [])
    ctx1 = DshBeam.Runtime.context(runtime1)
    {:ok, workspace1} = DshBeam.Context.get(ctx1, :workspace)

    {:ok, session1} = DshBeam.Workspace.open_session(workspace1, repo)
    %{cwd: cwd, title: title} = DshBeam.Session.header(session1)
    on_exit(fn -> File.rm_rf!(Path.dirname(cwd)) end)

    assert {:ok, _} = DshBeam.Session.append(session1, %{"role" => "user", "content" => "hello"})

    # tear down (release the session process + the runtime)
    Process.exit(session1, :shutdown)
    GenServer.stop(runtime1)

    # second mount: the roster restores the same session and its log
    {:ok, runtime2} = DshBeam.Runtime.start_link([entry], [])
    ctx2 = DshBeam.Runtime.context(runtime2)
    {:ok, workspace2} = DshBeam.Context.get(ctx2, :workspace)

    sessions = DshBeam.Workspace.all_sessions(workspace2)
    assert map_size(sessions) == 1

    [{restored, %{cwd: ^cwd}}] = Enum.to_list(sessions)
    assert DshBeam.Session.header(restored).title == title
    assert DshBeam.Session.all(restored) == [%{"role" => "user", "content" => "hello"}]

    # and the manifest is a JSON list of the roster entries
    assert [%{"cwd" => ^cwd, "title" => ^title} | _] = JSON.decode!(File.read!(roster_path))
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

  defp worktree_session(repo, branch) do
    dest =
      Path.join(System.tmp_dir!(), "dsh_ws_wt_#{branch}_#{System.unique_integer([:positive])}")

    assert {:ok, _} = DshBeam.Git.worktree_add(repo, branch, dest)
    on_exit(fn -> File.rm_rf!(dest) end)
    dest
  end

  defp age!(path) do
    File.touch!(path, {{2020, 1, 1}, {0, 0, 0}})
  end

  defp run_git(dir, args) do
    # CI runners have no git identity; supply one for every command (commit
    # needs it, and it is harmless for init/add/config).
    git = ["-c", "user.name=CI", "-c", "user.email=ci@example.com" | args]
    {_out, 0} = System.cmd("git", git, stderr_to_stdout: true, cd: dir)
    :ok
  end
end
