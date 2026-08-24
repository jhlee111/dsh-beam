defmodule DshBeam.Ui.TrajectoryProjectionTest do
  use ExUnit.Case, async: true

  test "from_events groups the log into turns and tags cells" do
    events = [
      %{"role" => "user", "content" => "task one"},
      %{"role" => "tool_call", "name" => "bash", "arguments" => %{"command" => "ls"}},
      %{"role" => "tool_result", "name" => "bash", "content" => "file.txt"},
      %{"role" => "assistant", "content" => "done"},
      %{"role" => "user", "content" => "task two"},
      %{"role" => "assistant", "content" => "answer"}
    ]

    assert [[t1, t2, t3, t4], [u1, u2]] = DshBeam.Ui.TrajectoryProjection.from_events(events)

    assert t1.kind == :user
    assert t2.kind == :tool
    assert t3.kind == :tool
    assert t4.kind == :message
    assert u1.kind == :user
    assert u2.kind == :message
  end

  test "cell maps each event role to a kind tag" do
    assert %{kind: :user, label: "USER"} =
             DshBeam.Ui.TrajectoryProjection.cell(%{"role" => "user", "content" => "hi"})

    assert %{kind: :message, label: "ASSISTANT"} =
             DshBeam.Ui.TrajectoryProjection.cell(%{"role" => "assistant", "content" => "hi"})

    assert %{kind: :tool, label: "TOOL"} =
             DshBeam.Ui.TrajectoryProjection.cell(%{"role" => "tool_call", "name" => "bash"})

    assert %{kind: :command, label: "COMMAND"} =
             DshBeam.Ui.TrajectoryProjection.cell(%{"role" => "command_run", "name" => "clear"})

    assert %{kind: :error, label: "ERROR"} =
             DshBeam.Ui.TrajectoryProjection.cell(%{"role" => "error", "content" => "boom"})
  end

  test "filter narrows turns by a case-insensitive substring query" do
    turns = [
      [%{kind: :user, label: "USER", text: "hello world"}],
      [%{kind: :message, label: "ASSISTANT", text: "goodbye"}]
    ]

    assert DshBeam.Ui.TrajectoryProjection.filter(turns, nil) == turns
    assert DshBeam.Ui.TrajectoryProjection.filter(turns, "") == turns

    assert DshBeam.Ui.TrajectoryProjection.filter(turns, "hello") == [
             [%{kind: :user, label: "USER", text: "hello world"}]
           ]

    assert DshBeam.Ui.TrajectoryProjection.filter(turns, "GOODBYE") == [
             [%{kind: :message, label: "ASSISTANT", text: "goodbye"}]
           ]

    assert DshBeam.Ui.TrajectoryProjection.filter(turns, "zzz") == []
  end
end
