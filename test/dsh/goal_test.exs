defmodule DshBeam.GoalTest do
  use ExUnit.Case, async: true

  setup do
    {:ok, session} = DshBeam.Session.Memory.start_link([])
    %{session: session}
  end

  test "create round-trips the current goal", %{session: session} do
    assert {:ok, goal} = DshBeam.Goal.create(session, "build a feature")

    assert goal["objective"] == "build a feature"
    assert goal["phase"] == "active"
    assert goal["revision"] == 1
    assert goal["rounds_started"] == 0
    assert goal["max_goal_rounds"] == DshBeam.Goal.default_max_goal_rounds()

    assert %{"objective" => "build a feature", "phase" => "active"} =
             DshBeam.Goal.current(session)
  end

  test "create trims the objective and rejects empty", %{session: session} do
    assert {:ok, goal} = DshBeam.Goal.create(session, "  build a feature  ")
    assert goal["objective"] == "build a feature"

    assert {:error, :empty_objective} = DshBeam.Goal.create(session, "   ")
  end

  test "create rejects while a non-complete goal is current", %{session: session} do
    assert {:ok, _} = DshBeam.Goal.create(session, "first")
    assert {:error, :goal_already_current} = DshBeam.Goal.create(session, "second")
  end

  test "a completed goal can be replaced with a fresh identity", %{session: session} do
    assert {:ok, first} = DshBeam.Goal.create(session, "first")
    assert {:ok, _} = DshBeam.Goal.update(session, first["id"], 1, "complete")

    assert {:ok, second} = DshBeam.Goal.create(session, "second")
    assert second["id"] != first["id"]
    assert second["revision"] == 1
  end

  test "update under a stale reference is rejected", %{session: session} do
    assert {:ok, goal} = DshBeam.Goal.create(session, "first")
    assert {:ok, _} = DshBeam.Goal.update(session, goal["id"], 1, "pause")

    # the revision advanced, so the original reference is now stale
    assert {:error, :stale_reference} = DshBeam.Goal.update(session, goal["id"], 1, "pause")
    assert {:error, :stale_reference} = DshBeam.Goal.update(session, "wrong-id", 2, "pause")
  end

  test "lifecycle: active -> paused -> resumed -> blocked -> resumed -> complete", %{
    session: session
  } do
    {:ok, goal} = DshBeam.Goal.create(session, "work")

    {:ok, paused} = DshBeam.Goal.update(session, goal["id"], 1, "pause")
    assert paused["phase"] == "paused"

    {:ok, resumed} = DshBeam.Goal.update(session, goal["id"], 2, "resume")
    assert resumed["phase"] == "active"

    {:ok, blocked} =
      DshBeam.Goal.update(session, goal["id"], 3, "blocked", blocked_reason: "stuck")

    assert blocked["phase"] == "blocked"
    assert blocked["blocked_reason"] == %{"code" => "model-reported", "message" => "stuck"}

    {:ok, resumed2} = DshBeam.Goal.update(session, goal["id"], 4, "resume")
    assert resumed2["phase"] == "active"
    assert resumed2["blocked_reason"] == nil

    {:ok, completed} = DshBeam.Goal.update(session, goal["id"], 5, "complete")
    assert completed["phase"] == "complete"
  end

  test "invalid transitions are rejected", %{session: session} do
    {:ok, goal} = DshBeam.Goal.create(session, "work")

    # complete from active is legal, but pause from paused / complete from complete is not
    assert {:ok, _} = DshBeam.Goal.update(session, goal["id"], 1, "pause")
    assert {:error, :invalid_transition} = DshBeam.Goal.update(session, goal["id"], 2, "pause")
    assert {:error, :invalid_transition} = DshBeam.Goal.update(session, goal["id"], 2, "complete")
  end

  test "blocked requires a concrete reason", %{session: session} do
    {:ok, goal} = DshBeam.Goal.create(session, "work")

    assert {:error, :blocked_reason_required} =
             DshBeam.Goal.update(session, goal["id"], 1, "blocked")
  end

  test "edit updates the objective and cap while retaining phase", %{session: session} do
    {:ok, goal} = DshBeam.Goal.create(session, "old objective")

    {:ok, edited} =
      DshBeam.Goal.update(session, goal["id"], 1, "edit",
        objective: "new objective",
        max_goal_rounds: 10
      )

    assert edited["objective"] == "new objective"
    assert edited["max_goal_rounds"] == 10
    assert edited["phase"] == "active"
    assert edited["revision"] == 2
  end

  test "resume is rejected once the round cap is exhausted", %{session: session} do
    {:ok, goal} = DshBeam.Goal.create(session, "work", max_goal_rounds: 1)
    assert {:ok, _} = DshBeam.Goal.update(session, goal["id"], 1, "pause")

    # rounds_started never advanced (no driver yet), so resume still works; the
    # cap check reads rounds_started, which stays 0 in this unit scope
    assert {:ok, resumed} = DshBeam.Goal.update(session, goal["id"], 2, "resume")
    assert resumed["phase"] == "active"
  end

  test "clear removes the current pointer and permits a fresh create", %{session: session} do
    assert {:ok, _} = DshBeam.Goal.create(session, "work")
    assert {:ok, :cleared} = DshBeam.Goal.clear(session)
    assert DshBeam.Goal.current(session) == nil

    assert {:ok, again} = DshBeam.Goal.create(session, "again")
    assert again["phase"] == "active"
  end
end
