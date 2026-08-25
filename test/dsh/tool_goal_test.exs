defmodule DshBeam.Tool.GoalTest do
  use ExUnit.Case, async: false

  defp session_entry,
    do: %{id: :session, plugin: DshBeam.Session.Plugin, config: [], disabled: false}

  defp goal_entry, do: %{id: :goal, plugin: DshBeam.Tool.Goal, config: [], disabled: false}

  test "get_goal returns null before any goal, then create/get/update round-trip" do
    {:ok, runtime} = DshBeam.Runtime.start_link([session_entry(), goal_entry()], [])
    ctx = DshBeam.Runtime.context(runtime)

    {:ok, get_goal} = DshBeam.Context.get(ctx, :get_goal)
    {:ok, create_goal} = DshBeam.Context.get(ctx, :create_goal)
    {:ok, update_goal} = DshBeam.Context.get(ctx, :update_goal)

    assert {:ok, ~s({"goal":null})} = DshBeam.Tool.call(get_goal, :get_goal, %{})

    assert {:ok, created} =
             DshBeam.Tool.call(create_goal, :create_goal, %{"objective" => "build a feature"})

    assert %{"goal" => %{"objective" => "build a feature", "phase" => "active", "revision" => 1}} =
             JSON.decode!(created)

    assert {:ok, got} = DshBeam.Tool.call(get_goal, :get_goal, %{})
    %{"goal" => goal} = JSON.decode!(got)
    assert is_binary(goal["id"])
    assert goal["revision"] == 1

    assert {:ok, completed} =
             DshBeam.Tool.call(update_goal, :update_goal, %{
               "goal_id" => goal["id"],
               "revision" => 1,
               "action" => "complete"
             })

    assert %{"goal" => %{"phase" => "complete", "revision" => 2}} = JSON.decode!(completed)

    # both mutations landed as durable goal_change events
    {:ok, session} = DshBeam.Context.get(ctx, :session)
    assert DshBeam.Session.all(session) |> Enum.map(& &1["operation"]) == ["create", "complete"]
  end

  test "update_goal under a stale revision is rejected" do
    {:ok, runtime} = DshBeam.Runtime.start_link([session_entry(), goal_entry()], [])
    ctx = DshBeam.Runtime.context(runtime)

    {:ok, create_goal} = DshBeam.Context.get(ctx, :create_goal)
    {:ok, update_goal} = DshBeam.Context.get(ctx, :update_goal)

    assert {:ok, created} =
             DshBeam.Tool.call(create_goal, :create_goal, %{"objective" => "work"})

    %{"goal" => %{"id" => id}} = JSON.decode!(created)

    assert {:error, :stale_reference} =
             DshBeam.Tool.call(update_goal, :update_goal, %{
               "goal_id" => id,
               "revision" => 99,
               "action" => "pause"
             })
  end

  test "create_goal is rejected while a non-complete goal is current" do
    {:ok, runtime} = DshBeam.Runtime.start_link([session_entry(), goal_entry()], [])
    ctx = DshBeam.Runtime.context(runtime)

    {:ok, create_goal} = DshBeam.Context.get(ctx, :create_goal)

    assert {:ok, _} = DshBeam.Tool.call(create_goal, :create_goal, %{"objective" => "first"})

    assert {:error, :goal_already_current} =
             DshBeam.Tool.call(create_goal, :create_goal, %{"objective" => "second"})
  end
end
