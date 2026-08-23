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

  test "memory provider: subscribe fans out each append to the subscriber" do
    {:ok, session} = DshBeam.Session.Memory.start_link([])

    :ok = DshBeam.Session.subscribe(session)
    assert {:ok, 1} = DshBeam.Session.append(session, %{"role" => "user", "content" => "hi"})
    assert_receive {:dsh_session_event, %{"role" => "user", "content" => "hi"}}, 1000

    # a second append reaches the same subscriber (still subscribed)
    assert {:ok, 2} = DshBeam.Session.append(session, %{"role" => "assistant", "content" => "yo"})
    assert_receive {:dsh_session_event, %{"role" => "assistant", "content" => "yo"}}, 1000
  end

  test "memory provider: a dead subscriber is cleaned up without breaking appends" do
    {:ok, session} = DshBeam.Session.Memory.start_link([])

    {:ok, sub} = Task.start(fn -> DshBeam.Session.subscribe(session) end)
    # the Task dies right after subscribing; the :DOWN should drop it
    ref = Process.monitor(sub)
    assert_receive {:DOWN, ^ref, :process, _pid, _reason}, 1000

    # appends still succeed after the subscriber death
    assert {:ok, 1} = DshBeam.Session.append(session, "a")
    assert DshBeam.Session.all(session) == ["a"]
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
