defmodule DshBeam.Agent.Loop do
  @moduledoc """
  The agent loop — a plugin that needs :llm and :session and runs the
  model↔tool loop: call the model with the available tools, dispatch tool
  calls through the tool registry, feed results back, and answer.

  The loop itself is a plugin like every other subsystem ("everything is a
  plugin"); tools are plugins too, discovered from the registry and filtered
  to those whose bindings are currently provided.
  """

  use DshBeam.Plugin

  need(:llm)
  need(:session)

  setting(:max_steps, type: :integer, default: 5, doc: "Max model↔tool round-trips")

  @doc "Run one task through the model↔tool loop. Returns {:ok, answer}."
  def run(loop, task) when is_pid(loop) and is_binary(task) do
    :gen_statem.call(loop, {:run, task})
  end

  @impl true
  def handle_event({:call, from}, {:run, task}, _state, data) do
    result = run_loop(data, task)
    {:keep_state_and_data, [{:reply, from, result}]}
  end

  defp run_loop(data, task) do
    case DshBeam.Context.resolve(data.ctx) do
      {:active, view} ->
        max_steps = Keyword.get(data.config, :max_steps, 5)

        system = %{
          "role" => "system",
          "content" => "You are a helpful agent. Use tools when needed."
        }

        messages = [system, %{"role" => "user", "content" => task}]
        loop(data.ctx, view.llm, view.session, messages, 0, max_steps)

      _ ->
        {:error, :capabilities_unavailable}
    end
  end

  defp loop(_ctx, _llm, _session, _messages, step, max_steps) when step >= max_steps do
    {:error, :max_steps}
  end

  defp loop(ctx, llm, session, messages, step, max_steps) do
    tools = available_tools(ctx)

    case DshBeam.Llm.chat(llm, messages, tools: tools) do
      {:ok, %{finish_reason: :tool_calls, tool_calls: [_ | _] = calls}} ->
        {assistant, tool_messages} = dispatch(ctx, calls)
        loop(ctx, llm, session, messages ++ [assistant | tool_messages], step + 1, max_steps)

      {:ok, %{content: content}} ->
        append_answer(session, task_of(messages), content)
        {:ok, content}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # the task is the first user message after the system prompt
  defp task_of(messages) do
    Enum.find_value(messages, fn m -> if m["role"] == "user", do: m["content"] end)
  end

  defp append_answer(session, task, content) do
    # log the turn to the session (the single source of truth)
    _ = DshBeam.Session.append(session, %{"role" => "user", "content" => task})
    _ = DshBeam.Session.append(session, %{"role" => "assistant", "content" => content})
    :ok
  end

  defp available_tools(ctx) do
    DshBeam.Tool.Registry.installed()
    |> Enum.filter(fn tool -> match?({:ok, _}, DshBeam.Context.get(ctx, tool.name)) end)
    |> Enum.map(fn tool ->
      %{
        "type" => "function",
        "function" => %{
          "name" => to_string(tool.name),
          "description" => tool.description,
          "parameters" => tool.parameters
        }
      }
    end)
  end

  defp dispatch(ctx, calls) do
    tool_messages = Enum.map(calls, &invoke_tool(ctx, &1))

    assistant = %{
      "role" => "assistant",
      "content" => nil,
      "tool_calls" =>
        Enum.map(calls, fn call ->
          %{
            "id" => call.id,
            "type" => "function",
            "function" => %{"name" => call.name, "arguments" => call.arguments}
          }
        end)
    }

    {assistant, tool_messages}
  end

  defp invoke_tool(ctx, %{id: id, name: name, arguments: arguments}) do
    args = decode_arguments(arguments)

    result =
      case safe_atom(name) do
        nil ->
          {:error, "unknown tool #{name}"}

        tool_name ->
          case DshBeam.Context.get(ctx, tool_name) do
            {:ok, provider} -> DshBeam.Tool.call(provider, tool_name, args)
            :not_found -> {:error, "tool #{name} not available"}
          end
      end

    %{
      "role" => "tool",
      "tool_call_id" => id,
      "content" =>
        case result do
          {:ok, value} -> to_string(value)
          {:error, reason} -> "error: " <> inspect(reason)
        end
    }
  end

  defp safe_atom(name) do
    try do
      String.to_existing_atom(name)
    rescue
      ArgumentError -> nil
    end
  end

  defp decode_arguments(arguments) do
    case JSON.decode(arguments) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end
end
