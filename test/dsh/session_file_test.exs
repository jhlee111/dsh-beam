defmodule DshBeam.Session.FileTest do
  use ExUnit.Case, async: false

  defp tmp_path do
    Path.join(System.tmp_dir!(), "dsh_sf_#{System.unique_integer([:positive])}.jsonl")
  end

  test "append/read round-trips unicode content" do
    path = tmp_path()
    on_exit(fn -> File.rm(path) end)

    {:ok, session} = DshBeam.Session.File.start(path: path, title: "t", cwd: "/x")

    assert {:ok, _} =
             DshBeam.Session.append(session, %{"role" => "user", "content" => "안녕하세요 한글"})

    assert {:ok, _} =
             DshBeam.Session.append(session, %{"role" => "assistant", "content" => "emoji 🎉"})

    assert [%{"content" => "안녕하세요 한글"}, %{"content" => "emoji 🎉"}] =
             DshBeam.Session.all(session)
  end

  test "a restarted provider reloads the log from disk" do
    path = tmp_path()
    on_exit(fn -> File.rm(path) end)

    {:ok, session} = DshBeam.Session.File.start(path: path, title: "t", cwd: "/x")
    DshBeam.Session.append(session, %{"role" => "user", "content" => "한글"})
    Process.exit(session, :shutdown)

    {:ok, session2} = DshBeam.Session.File.start(path: path, title: "t", cwd: "/x")
    assert DshBeam.Session.all(session2) == [%{"role" => "user", "content" => "한글"}]
  end
end
