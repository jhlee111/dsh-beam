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

  test "cell captures reasoning and a compact usage summary" do
    assert %{kind: :reasoning, label: "THINK"} =
             DshBeam.Ui.TrajectoryProjection.cell(%{
               "role" => "reasoning_chunk",
               "content" => "chain of thought"
             })

    cell =
      DshBeam.Ui.TrajectoryProjection.cell(%{
        "role" => "assistant",
        "content" => "answer",
        "usage" => %{input_tokens: 100, output_tokens: 50}
      })

    assert cell.text == "answer · 100 in / 50 out"

    # no usage → no suffix
    assert DshBeam.Ui.TrajectoryProjection.cell(%{"role" => "assistant", "content" => "answer"}).text ==
             "answer"
  end

  test "from_events groups by turn_start and surfaces request/turn_end cells" do
    events = [
      %{"role" => "turn_start", "turn" => 1},
      %{"role" => "user", "content" => "task"},
      %{
        "role" => "request",
        "usage" => %{input_tokens: 10, output_tokens: 5},
        "started_at" => 100,
        "completed_at" => 180
      },
      %{"role" => "assistant", "content" => "done"},
      %{"role" => "turn_end", "reason" => "completed"},
      %{"role" => "turn_start", "turn" => 2},
      %{"role" => "user", "content" => "task 2"},
      %{"role" => "assistant", "content" => "answer"},
      %{"role" => "turn_end", "reason" => "completed"}
    ]

    assert [
             [turn1_user, turn1_request, turn1_assistant, turn1_end],
             [turn2_user, turn2_assistant, turn2_end]
           ] =
             DshBeam.Ui.TrajectoryProjection.from_events(events)

    # turn_start is a pure boundary: no cell
    assert turn1_user.kind == :user

    # request cell: duration + usage
    assert turn1_request.kind == :request
    assert turn1_request.text == "80ms · 10 in / 5 out"

    assert turn1_end.kind == :turn_end
    assert turn1_end.text == "completed"
  end

  test "cell maps a request to its duration + usage summary" do
    cell =
      DshBeam.Ui.TrajectoryProjection.cell(%{
        "role" => "request",
        "usage" => nil,
        "started_at" => 1000,
        "completed_at" => 1250
      })

    assert cell.kind == :request
    assert cell.text == "250ms"

    assert DshBeam.Ui.TrajectoryProjection.cell(%{"role" => "turn_end", "reason" => "aborted"}).text ==
             "aborted"
  end
end
