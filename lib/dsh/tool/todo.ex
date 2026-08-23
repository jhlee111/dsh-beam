defmodule DshBeam.Tool.Todo do
  @moduledoc """
  The todo tool — the harness's tool-todo: the agent maintains a whole-list
  todo snapshot through the model-visible `todo_write` tool.

  Port of the reference `todo/write` session event: every call carries the
  COMPLETE replacement list (last-write-wins), so the list needs no stable
  per-item identity — each item is a `content` line and a three-state status.
  The write lands in the session log, so the console renders the latest
  snapshot as a projection of the session (the single source of truth).
  """

  use DshBeam.Plugin

  need(:session)

  @statuses ~w(pending in_progress completed)

  tool(:todo_write,
    description: "Replace the agent's todo list with the given items (whole-list snapshot)",
    parameters: %{
      "type" => "object",
      "properties" => %{
        "todos" => %{
          "type" => "array",
          "description" => "The complete replacement todo list",
          "items" => %{
            "type" => "object",
            "properties" => %{
              "content" => %{"type" => "string", "description" => "a short imperative task line"},
              "status" => %{
                "type" => "string",
                "enum" => @statuses
              }
            },
            "required" => ["content", "status"]
          }
        }
      },
      "required" => ["todos"]
    }
  )

  @impl DshBeam.Plugin
  def handle_dsh_tool_call(:todo_write, %{"todos" => todos}, state) do
    with {:ok, normalized} <- normalize(todos),
         {:ok, session} <- session(state) do
      _ = DshBeam.Session.append(session, %{"role" => "todo_write", "todos" => normalized})
      {:ok, "todo list updated (#{length(normalized)} items)"}
    end
  end

  defp normalize(todos) when is_list(todos) do
    normalized =
      Enum.map(todos, fn
        %{"content" => content, "status" => status}
        when is_binary(content) and status in @statuses ->
          {:ok, %{"content" => content, "status" => status}}

        _ ->
          {:error, :invalid_item}
      end)

    if Enum.any?(normalized, &match?({:error, _}, &1)) do
      {:error, :invalid_todo_item}
    else
      {:ok, Enum.map(normalized, fn {:ok, item} -> item end)}
    end
  end

  defp normalize(_), do: {:error, :todos_not_a_list}

  defp session(state) do
    case DshBeam.Context.resolve(state.ctx) do
      {:active, %{session: session}} -> {:ok, session}
      _ -> {:error, :session_unavailable}
    end
  end
end
