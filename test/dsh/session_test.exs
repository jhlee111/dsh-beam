defmodule Dsh.SessionTest do
  use ExUnit.Case, async: true

  test "memory provider: append assigns seq and reads back in order" do
    {:ok, session} = Dsh.Session.Memory.start_link([])

    assert {:ok, 1} = Dsh.Session.append(session, "a")
    assert {:ok, 2} = Dsh.Session.append(session, "b")
    assert {:ok, 3} = Dsh.Session.append(session, "c")

    assert Dsh.Session.all(session) == ["a", "b", "c"]
    assert Dsh.Session.count(session) == 3
  end

  test "file provider: appends persist across restarts" do
    path = Path.join(System.tmp_dir!(), "dsh_session_#{System.unique_integer([:positive])}.jsonl")
    on_exit(fn -> File.rm(path) end)

    {:ok, session} = Dsh.Session.File.start_link(path: path)
    assert {:ok, 1} = Dsh.Session.append(session, %{"role" => "user", "text" => "hi"})
    assert {:ok, 2} = Dsh.Session.append(session, %{"role" => "assistant", "text" => "yo"})
    assert Dsh.Session.count(session) == 2

    GenServer.stop(session)
    {:ok, reopened} = Dsh.Session.File.start_link(path: path)

    assert Dsh.Session.all(reopened) == [
             %{"role" => "user", "text" => "hi"},
             %{"role" => "assistant", "text" => "yo"}
           ]
  end
end
