defmodule DshBeam.Tool.TodoTest do
  use ExUnit.Case, async: false

  defp session_entry,
    do: %{id: :session, plugin: DshBeam.Session.Plugin, config: [], disabled: false}

  defp todo_entry, do: %{id: :todo, plugin: DshBeam.Tool.Todo, config: [], disabled: false}

  test "todo_write appends a whole-list snapshot to the session" do
    {:ok, runtime} = DshBeam.Runtime.start_link([session_entry(), todo_entry()], [])
    ctx = DshBeam.Runtime.context(runtime)

    {:ok, todo} = DshBeam.Context.get(ctx, :todo_write)

    todos = [
      %{"content" => "inspect the workspace", "status" => "in_progress"},
      %{"content" => "write a summary", "status" => "pending"}
    ]

    assert {:ok, "todo list updated (2 items)"} =
             DshBeam.Tool.call(todo, :todo_write, %{"todos" => todos})

    {:ok, session} = DshBeam.Context.get(ctx, :session)
    assert [%{"role" => "todo_write", "todos" => ^todos}] = DshBeam.Session.all(session)
  end

  test "todo_write is last-write-wins: the second snapshot replaces the first" do
    {:ok, runtime} = DshBeam.Runtime.start_link([session_entry(), todo_entry()], [])
    ctx = DshBeam.Runtime.context(runtime)

    {:ok, todo} = DshBeam.Context.get(ctx, :todo_write)

    first = [%{"content" => "a", "status" => "pending"}]
    second = [%{"content" => "b", "status" => "completed"}]

    assert {:ok, _} = DshBeam.Tool.call(todo, :todo_write, %{"todos" => first})
    assert {:ok, _} = DshBeam.Tool.call(todo, :todo_write, %{"todos" => second})

    {:ok, session} = DshBeam.Context.get(ctx, :session)

    assert DshBeam.Session.all(session) == [
             %{"role" => "todo_write", "todos" => first},
             %{"role" => "todo_write", "todos" => second}
           ]
  end

  test "todo_write rejects an invalid item status" do
    {:ok, runtime} = DshBeam.Runtime.start_link([session_entry(), todo_entry()], [])
    ctx = DshBeam.Runtime.context(runtime)

    {:ok, todo} = DshBeam.Context.get(ctx, :todo_write)

    assert {:error, :invalid_todo_item} =
             DshBeam.Tool.call(todo, :todo_write, %{
               "todos" => [%{"content" => "x", "status" => "bogus"}]
             })
  end

  test "removing :session deactivates the todo tool first (the guard)" do
    {:ok, runtime} = DshBeam.Runtime.start_link([session_entry(), todo_entry()], [])
    ctx = DshBeam.Runtime.context(runtime)

    {:ok, todo} = DshBeam.Context.get(ctx, :todo_write)
    :ok = DshBeam.Runtime.reconcile(runtime, [todo_entry()])

    history = DshBeam.Context.history(ctx)
    deactivated = Enum.find_index(history, &match?({:deactivated, pid} when pid == todo, &1))
    assert deactivated != nil
    assert DshBeam.Plugin.fiber_state(todo) == :inactive
  end
end
