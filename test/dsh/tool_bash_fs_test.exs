defmodule DshBeam.Tool.BashFsTest do
  use ExUnit.Case, async: false

  test "the bash tool runs a command through the shell" do
    shell_entry = %{id: :shell, plugin: DshBeam.Shell.Plugin, config: [], disabled: false}
    bash_entry = %{id: :bash, plugin: DshBeam.Tool.Bash, config: [], disabled: false}

    {:ok, runtime} = DshBeam.Runtime.start_link([shell_entry, bash_entry], [])
    ctx = DshBeam.Runtime.context(runtime)

    {:ok, bash} = DshBeam.Context.get(ctx, :bash)
    assert {:ok, "hi\n"} = DshBeam.Tool.call(bash, :bash, %{"command" => "echo hi"})
  end

  test "removing :shell deactivates the bash tool first (the guard)" do
    session_entry = %{id: :session, plugin: DshBeam.Session.Plugin, config: [], disabled: false}
    shell_entry = %{id: :shell, plugin: DshBeam.Shell.Plugin, config: [], disabled: false}
    bash_entry = %{id: :bash, plugin: DshBeam.Tool.Bash, config: [], disabled: false}

    {:ok, runtime} = DshBeam.Runtime.start_link([session_entry, shell_entry, bash_entry], [])
    ctx = DshBeam.Runtime.context(runtime)

    {:ok, bash} = DshBeam.Context.get(ctx, :bash)
    :ok = DshBeam.Runtime.reconcile(runtime, [session_entry, bash_entry])

    history = DshBeam.Context.history(ctx)
    deactivated = Enum.find_index(history, &match?({:deactivated, pid} when pid == bash, &1))
    unloaded = Enum.find_index(history, &match?({:unloaded, _pid}, &1))
    assert deactivated != nil and unloaded != nil and deactivated < unloaded

    assert DshBeam.Plugin.fiber_state(bash) == :inactive
  end

  test "the bash tool runs in the current session's worktree" do
    dir = Path.join(System.tmp_dir!(), "dsh_bash_cwd_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    session_entry = %{
      id: :session,
      plugin: DshBeam.Session.Plugin,
      config: [cwd: dir],
      disabled: false
    }

    shell_entry = %{id: :shell, plugin: DshBeam.Shell.Plugin, config: [], disabled: false}
    bash_entry = %{id: :bash, plugin: DshBeam.Tool.Bash, config: [], disabled: false}

    {:ok, runtime} = DshBeam.Runtime.start_link([session_entry, shell_entry, bash_entry], [])
    ctx = DshBeam.Runtime.context(runtime)

    {:ok, bash} = DshBeam.Context.get(ctx, :bash)
    assert {:ok, _} = DshBeam.Tool.call(bash, :bash, %{"command" => "touch marker.txt"})

    # the command's effect landed in the session's cwd (not the shell's)
    assert File.exists?(Path.join(dir, "marker.txt"))
  end

  test "the fs tool reads and writes within the workspace root" do
    root = Path.join(System.tmp_dir!(), "dsh_fs_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    fs_entry = %{id: :fs, plugin: DshBeam.Tool.Fs, config: [root: root], disabled: false}
    {:ok, runtime} = DshBeam.Runtime.start_link([fs_entry], [])
    ctx = DshBeam.Runtime.context(runtime)

    {:ok, fs} = DshBeam.Context.get(ctx, :read_file)

    assert {:ok, "wrote notes.txt"} =
             DshBeam.Tool.call(fs, :write_file, %{"path" => "notes.txt", "content" => "hello"})

    assert {:ok, "hello"} = DshBeam.Tool.call(fs, :read_file, %{"path" => "notes.txt"})
  end

  test "the fs tool rejects paths that escape the workspace" do
    root = Path.join(System.tmp_dir!(), "dsh_fs_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    fs_entry = %{id: :fs, plugin: DshBeam.Tool.Fs, config: [root: root], disabled: false}
    {:ok, runtime} = DshBeam.Runtime.start_link([fs_entry], [])
    ctx = DshBeam.Runtime.context(runtime)

    {:ok, fs} = DshBeam.Context.get(ctx, :read_file)

    assert {:error, :escapes_workspace} =
             DshBeam.Tool.call(fs, :read_file, %{"path" => "../outside.txt"})
  end

  test "the fs tool writes into the current session's worktree, not the config root" do
    worktree = Path.join(System.tmp_dir!(), "dsh_fs_wt_#{System.unique_integer([:positive])}")

    stale_root =
      Path.join(System.tmp_dir!(), "dsh_fs_stale_#{System.unique_integer([:positive])}")

    File.mkdir_p!(worktree)
    File.mkdir_p!(stale_root)

    on_exit(fn ->
      File.rm_rf!(worktree)
      File.rm_rf!(stale_root)
    end)

    session_entry = %{
      id: :session,
      plugin: DshBeam.Session.Plugin,
      config: [cwd: worktree],
      disabled: false
    }

    fs_entry = %{id: :fs, plugin: DshBeam.Tool.Fs, config: [root: stale_root], disabled: false}

    {:ok, runtime} = DshBeam.Runtime.start_link([session_entry, fs_entry], [])
    ctx = DshBeam.Runtime.context(runtime)

    {:ok, fs} = DshBeam.Context.get(ctx, :write_file)

    assert {:ok, "wrote notes.txt"} =
             DshBeam.Tool.call(fs, :write_file, %{"path" => "notes.txt", "content" => "hi"})

    assert File.exists?(Path.join(worktree, "notes.txt"))
    refute File.exists?(Path.join(stale_root, "notes.txt"))
  end
end
