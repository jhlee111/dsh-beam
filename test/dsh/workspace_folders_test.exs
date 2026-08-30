defmodule DshBeam.WorkspaceFoldersTest do
  use ExUnit.Case, async: false

  setup do
    dir = Path.join(System.tmp_dir!(), "dsh_wf_#{System.unique_integer([:positive])}")
    ro = Path.join(System.tmp_dir!(), "dsh_wf_ro_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.mkdir_p!(ro)

    on_exit(fn ->
      File.rm_rf!(dir)
      File.rm_rf!(ro)
    end)

    {:ok, runtime} = DshBeam.Runtime.start_link([], [])
    ctx = DshBeam.Runtime.context(runtime)

    session_entry = %{
      id: :session,
      plugin: DshBeam.Session.Plugin,
      config: [cwd: dir],
      disabled: false
    }

    fs_entry = %{id: :fs, plugin: DshBeam.Tool.Fs, config: [], disabled: false}

    wf_entry = %{
      id: :workspace_folders,
      plugin: DshBeam.WorkspaceFolders,
      config: [extra_folders: "w #{dir}\nr #{ro}"],
      disabled: false
    }

    :ok = DshBeam.Runtime.reconcile(runtime, [session_entry, fs_entry, wf_entry])

    {:ok, read} = DshBeam.Context.get(ctx, :read_file)
    {:ok, write} = DshBeam.Context.get(ctx, :write_file)
    {:ok, wf} = DshBeam.Context.get(ctx, :workspace_folders)

    %{runtime: runtime, ctx: ctx, dir: dir, ro: ro, read: read, write: write, wf: wf}
  end

  test "the plugin provides the parsed folder list with writable flags", %{wf: wf} do
    assert length(wf) == 2
    assert Enum.any?(wf, &(&1.writable == true))
    assert Enum.any?(wf, &(&1.writable == false))
  end

  test "the fs tool writes into the session root and a writable extra folder", %{
    write: write,
    dir: dir
  } do
    assert {:ok, "wrote in-session.txt"} =
             DshBeam.Tool.call(write, :write_file, %{"path" => "in-session.txt", "content" => "s"})

    assert File.exists?(Path.join(dir, "in-session.txt"))

    assert {:ok, _} =
             DshBeam.Tool.call(write, :write_file, %{
               "path" => Path.join(dir, "extra.txt"),
               "content" => "e"
             })

    assert File.exists?(Path.join(dir, "extra.txt"))
  end

  test "the fs tool refuses writes on a read-only extra folder", %{write: write, ro: ro} do
    assert {:error, :readonly_folder} =
             DshBeam.Tool.call(write, :write_file, %{
               "path" => Path.join(ro, "no.txt"),
               "content" => "x"
             })

    refute File.exists?(Path.join(ro, "no.txt"))
  end

  test "the fs tool reads from a read-only extra folder", %{read: read, ro: ro} do
    File.write!(Path.join(ro, "ro.txt"), "hi")
    assert {:ok, "hi"} = DshBeam.Tool.call(read, :read_file, %{"path" => Path.join(ro, "ro.txt")})
  end

  test "paths outside the session root and the added folders are refused", %{read: read} do
    assert {:error, :escapes_workspace} =
             DshBeam.Tool.call(read, :read_file, %{"path" => "/etc/hosts"})
  end

  test "without the plugin the fs tool behaviour is unchanged", _context do
    root = Path.join(System.tmp_dir!(), "dsh_wf_none_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, runtime} = DshBeam.Runtime.start_link([], [])
    ctx = DshBeam.Runtime.context(runtime)

    session_entry = %{
      id: :session,
      plugin: DshBeam.Session.Plugin,
      config: [cwd: root],
      disabled: false
    }

    fs_entry = %{id: :fs, plugin: DshBeam.Tool.Fs, config: [], disabled: false}

    :ok = DshBeam.Runtime.reconcile(runtime, [session_entry, fs_entry])

    {:ok, read} = DshBeam.Context.get(ctx, :read_file)
    {:ok, write} = DshBeam.Context.get(ctx, :write_file)

    assert {:ok, "wrote a.txt"} =
             DshBeam.Tool.call(write, :write_file, %{"path" => "a.txt", "content" => "x"})

    assert {:error, :escapes_workspace} =
             DshBeam.Tool.call(read, :read_file, %{"path" => "/etc/hosts"})
  end
end
