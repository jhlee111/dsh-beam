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
end
