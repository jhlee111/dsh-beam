defmodule DshBeam.SessionTest do
  use ExUnit.Case, async: true

  test "memory provider: append assigns seq and reads back in order" do
    {:ok, session} = DshBeam.Session.Memory.start_link([])

    assert {:ok, 1} = DshBeam.Session.append(session, "a")
    assert {:ok, 2} = DshBeam.Session.append(session, "b")
    assert {:ok, 3} = DshBeam.Session.append(session, "c")

    assert DshBeam.Session.all(session) == ["a", "b", "c"]
    assert DshBeam.Session.count(session) == 3
  end

  test "file provider: appends persist across restarts" do
    path = Path.join(System.tmp_dir!(), "dsh_session_#{System.unique_integer([:positive])}.jsonl")
    on_exit(fn -> File.rm(path) end)

    {:ok, session} = DshBeam.Session.File.start_link(path: path)
    assert {:ok, 1} = DshBeam.Session.append(session, %{"role" => "user", "text" => "hi"})
    assert {:ok, 2} = DshBeam.Session.append(session, %{"role" => "assistant", "text" => "yo"})
    assert DshBeam.Session.count(session) == 2

    GenServer.stop(session)
    {:ok, reopened} = DshBeam.Session.File.start_link(path: path)

    assert DshBeam.Session.all(reopened) == [
             %{"role" => "user", "text" => "hi"},
             %{"role" => "assistant", "text" => "yo"}
           ]
  end
end
