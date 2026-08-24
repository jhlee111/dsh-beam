defmodule DshBeam.Agent.Loop do
  @moduledoc """
  The agent loop — a plugin that needs :llm and :session and runs the
  model↔tool loop: call the model with the available tools, dispatch tool
  calls through the tool registry, feed results back, and answer.

  The loop itself is a plugin like every other subsystem ("everything is a
  plugin"); tools are plugins too, discovered from the registry and filtered
  to those whose bindings are currently provided.

  run_trace/2 returns the answer plus the step trace, so a UI can render the
  loop as it happens: {:tool_call, name, args} and {:tool_result, name, result}.
  """

  use DshBeam.Plugin

  need(:llm)
  need(:session)

  setting(:max_steps, type: :integer, default: 20, doc: "Max model↔tool round-trips")

  @typedoc "One loop step: a tool call or its result."
  @type step ::
          {:tool_call, String.t(), map()} | {:tool_result, String.t(), String.t()}

  @doc "Run one task through the model↔tool loop. Returns {:ok, answer}."
  def run(loop, task) when is_pid(loop) and is_binary(task) do
    run(loop, task, nil)
  end

  @doc "Run one task under a cancellation token. Returns {:ok, answer}."
  def run(loop, task, token) when is_pid(loop) and is_binary(task) do
    case :gen_statem.call(loop, {:run, task, token}) do
      {:ok, answer, _trace} -> {:ok, answer}
      other -> other
    end
  end

  @doc "Run one task and return {:ok, answer, trace} (the loop's steps)."
  def run_trace(loop, task) when is_pid(loop) and is_binary(task) do
    run_trace(loop, task, nil)
  end

  @doc "Run one task under a cancellation token, returning the step trace."
  def run_trace(loop, task, token) when is_pid(loop) and is_binary(task) do
    :gen_statem.call(loop, {:run_trace, task, token})
  end

  @impl true
  def handle_event({:call, from}, {:run, task}, _state, data) do
    {:keep_state_and_data, [{:reply, from, run_loop(data, task, nil)}]}
  end

  def handle_event({:call, from}, {:run, task, token}, _state, data) do
    {:keep_state_and_data, [{:reply, from, run_loop(data, task, token)}]}
  end

  def handle_event({:call, from}, {:run_trace, task}, _state, data) do
    {:keep_state_and_data, [{:reply, from, run_loop(data, task, nil)}]}
  end

  def handle_event({:call, from}, {:run_trace, task, token}, _state, data) do
    {:keep_state_and_data, [{:reply, from, run_loop(data, task, token)}]}
  end

  defp run_loop(data, task, token) do
    case DshBeam.Context.resolve(data.ctx) do
      {:active, view} ->
        max_steps = Keyword.get(data.config, :max_steps, 20)

        system = %{
          "role" => "system",
          "content" => DshBeam.SystemPrompt.render()
        }

        # Multi-turn: the session log is the single source of truth. Project it
        # to the model wire shape FIRST (a deterministic, append-ordered replay
        # of user/assistant/tool turns), then record the new turn (turn_start +
        # user) so the replay and the record stay consistent. The projection
        # preserves tool turns, so the prompt prefix is stable across requests
        # and runs — cache-friendly, like the reference's deriveMessages.
        history = DshBeam.Agent.Loop.Projection.from_session(view.session)
        turn = next_turn(view.session)

        _ = DshBeam.Session.append(view.session, %{"role" => "turn_start", "turn" => turn})
        _ = DshBeam.Session.append(view.session, %{"role" => "user", "content" => task})

        messages = [system | history] ++ [%{"role" => "user", "content" => task}]

        result =
          loop(
            data.ctx,
            view.llm,
            view.session,
            messages,
            0,
            max_steps,
            [],
            DshBeam.Guard.RepeatToolReminder.new(),
            token
          )

        _ = append_turn_end(view.session, result)
        result

      _ ->
        {:error, :capabilities_unavailable}
    end
  end

  defp loop(_ctx, _llm, session, _messages, step, max_steps, _trace, _repeat, _token)
       when step >= max_steps do
    _ = DshBeam.Session.append(session, %{"role" => "error", "content" => "max_steps"})
    {:error, :max_steps}
  end

  defp loop(ctx, llm, session, messages, step, max_steps, trace, repeat, token) do
    if DshBeam.Agent.Cancel.cancelled?(token) do
      abort(session)
      {:error, :stopped, Enum.reverse(trace)}
    else
      tools = available_tools(ctx)
      started_at = System.monotonic_time(:millisecond)

      case DshBeam.Llm.chat(llm, messages,
             tools: tools,
             cancel: token,
             stream: reasoning_stream(session)
           ) do
        {:ok, %{finish_reason: :tool_calls, tool_calls: [_ | _] = calls} = reply} ->
          append_request(session, reply, started_at)

          {assistant, tool_messages, steps} = dispatch(ctx, calls, token)

          # record the whole assistant turn — the model-issued tool calls AND
          # their results — into the session (chronological), so the chat pane
          # shows tool execution, survives a refresh, and the NEXT turn replays
          # the full prefix (cache-friendly, like the reference's deriveMessages).
          append_steps(session, calls, tool_messages)

          # the harness's guard/repeat-tool-reminder: count consecutive identical
          # tool calls and inject an advisory nudge when a threshold is hit
          {repeat, reminder} = track_repeats(repeat, calls)
          messages = maybe_remind(messages ++ [assistant | tool_messages], reminder)

          loop(
            ctx,
            llm,
            session,
            messages,
            step + 1,
            max_steps,
            Enum.reverse(steps) ++ trace,
            repeat,
            token
          )

        {:ok, %{content: content} = reply} ->
          append_request(session, reply, started_at)

          # Reasoning is display-only (never re-sent to the model); usage rides
          # the assistant event so the trajectory can show per-turn tokens.
          append_reasoning(session, Map.get(reply, :reasoning))

          _ =
            DshBeam.Session.append(session, %{
              "role" => "assistant",
              "content" => content,
              "usage" => Map.get(reply, :usage)
            })

          {:ok, content, Enum.reverse(trace)}

        {:error, :cancelled} ->
          abort(session)
          {:error, :stopped, Enum.reverse(trace)}

        {:error, reason} ->
          _ = DshBeam.Session.append(session, %{"role" => "error", "content" => inspect(reason)})
          {:error, reason}
      end
    end
  end

  # Record a user-initiated stop as a terminal turn event. The loop is the
  # single writer of the turn's session events, so the UI only signals the
  # token and the loop authors this row (the reference's `turn/end` reason
  # `aborted`).
  defp abort(session) do
    _ = DshBeam.Session.append(session, %{"role" => "error", "content" => "stopped by user"})
    :ok
  end

  # Record a reasoning block (chain-of-thought) as a display-only session event,
  # just before the assistant answer it explains. Non-streaming adapters return
  # the whole block at once, so it lands as a single reasoning_chunk; a
  # streaming adapter emits many chunks through reasoning_stream/1 instead.
  defp append_reasoning(_session, nil), do: :ok
  defp append_reasoning(_session, ""), do: :ok

  defp append_reasoning(session, reasoning) when is_binary(reasoning) do
    DshBeam.Session.append(session, %{"role" => "reasoning_chunk", "content" => reasoning})
  end

  # The stream callback the adapter invokes per reasoning chunk as the model
  # thinks; each chunk is a durable session event the chat pane folds live.
  defp reasoning_stream(session) do
    fn
      {:reasoning, chunk} when is_binary(chunk) ->
        DshBeam.Session.append(session, %{"role" => "reasoning_chunk", "content" => chunk})
        :ok

      _other ->
        :ok
    end
  end

  # The turn number is one more than the turn_start events already in the log
  # (the log is the single source of truth for the ordinal).
  defp next_turn(session) do
    count = session |> DshBeam.Session.all() |> Enum.count(&(&1["role"] == "turn_start"))
    count + 1
  end

  # Record one model request's durable facts: token usage and wall-clock timing
  # (the reference's request/context). Errors and cancellation record their own
  # terminal event instead, so no request row is appended on those paths.
  defp append_request(session, reply, started_at) do
    DshBeam.Session.append(session, %{
      "role" => "request",
      "usage" => Map.get(reply, :usage),
      "started_at" => started_at,
      "completed_at" => System.monotonic_time(:millisecond)
    })
  end

  # Close the turn with its outcome (the reference's turn/end reason).
  defp append_turn_end(session, result) do
    reason =
      case result do
        {:ok, _, _} -> "completed"
        {:error, :stopped, _trace} -> "aborted"
        {:error, :max_steps} -> "max_steps"
        {:error, reason} -> inspect(reason)
      end

    DshBeam.Session.append(session, %{"role" => "turn_end", "reason" => reason})
  end

  defp track_repeats(repeat, calls) do
    Enum.reduce(calls, {repeat, nil}, fn call, {rep, _rem} ->
      args = decode_arguments(call.arguments)
      {new_rep, reminder} = DshBeam.Guard.RepeatToolReminder.track(rep, call.name, args)
      {new_rep, reminder}
    end)
  end

  defp maybe_remind(messages, nil), do: messages

  defp maybe_remind(messages, reminder) do
    messages ++ [%{"role" => "user", "content" => reminder}]
  end

  # Persist a tool step: first every model-issued call (the UI card + the
  # projection's assistant tool_calls source), then every result (the UI card +
  # the projection's tool message source). All calls before all results keeps
  # the projection's turn grouping correct when a model emits several calls.
  defp append_steps(session, calls, tool_messages) do
    Enum.each(calls, fn call ->
      DshBeam.Session.append(session, %{
        "role" => "tool_call",
        "id" => call.id,
        "name" => call.name,
        "arguments" => decode_arguments(call.arguments),
        "arguments_json" => call.arguments
      })
    end)

    Enum.zip(calls, tool_messages)
    |> Enum.each(fn {call, tool_message} ->
      DshBeam.Session.append(session, %{
        "role" => "tool_result",
        "tool_call_id" => tool_message["tool_call_id"],
        "name" => call.name,
        "content" => tool_message["content"]
      })
    end)

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

  defp dispatch(ctx, calls, token) do
    {tool_messages, steps} =
      calls
      |> Enum.map(&invoke_tool(ctx, &1, token))
      |> Enum.reduce({[], []}, fn {tool_message, step_call, step_result}, {tms, steps} ->
        {tms ++ [tool_message], steps ++ [step_call, step_result]}
      end)

    # content is "" (never nil) on a tool-call turn: some OpenAI-compatible
    # gateways reject a null content, and an empty string keeps the session
    # projection identical to what was sent (the reference does the same).
    assistant = %{
      "role" => "assistant",
      "content" => "",
      "tool_calls" =>
        Enum.map(calls, fn call ->
          %{
            "id" => call.id,
            "type" => "function",
            "function" => %{"name" => call.name, "arguments" => call.arguments}
          }
        end)
    }

    {assistant, tool_messages, steps}
  end

  defp invoke_tool(ctx, %{id: id, name: name, arguments: arguments}, token) do
    # A token cancelled while the model's tool calls are being dispatched skips
    # the remaining calls: each records a synthetic "aborted before dispatch"
    # result (the reference's appendSkippedToolCall) so the session replay stays
    # valid, and the loop's next step boundary turns it into a stop.
    if DshBeam.Agent.Cancel.cancelled?(token) do
      result_string = "Error: tool call aborted before dispatch"

      tool_message = %{"role" => "tool", "tool_call_id" => id, "content" => result_string}

      {tool_message, {:tool_call, name, %{}}, {:tool_result, name, result_string}}
    else
      args = decode_arguments(arguments)

      result_string =
        case safe_atom(name) do
          nil ->
            "error: unknown tool #{name}"

          tool_name ->
            case DshBeam.Context.get(ctx, tool_name) do
              {:ok, provider} ->
                # the harness's guard/timeout-policy: read the tool's declared
                # cooperative budget and bound the call so a hung tool cannot
                # stall the loop
                DshBeam.Guard.TimeoutPolicy.invoke(provider, tool_name, args, timeout(tool_name))
                |> result_string()

              :not_found ->
                "error: tool #{name} not available"
            end
        end

      tool_message = %{"role" => "tool", "tool_call_id" => id, "content" => result_string}

      {tool_message, {:tool_call, name, args}, {:tool_result, name, result_string}}
    end
  end

  defp safe_atom(name) do
    try do
      String.to_existing_atom(name)
    rescue
      ArgumentError -> nil
    end
  end

  defp timeout(name), do: DshBeam.Tool.Registry.timeout(name)

  defp result_string({:ok, value}), do: to_string(value)
  defp result_string({:error, reason}), do: "error: " <> inspect(reason)

  defp decode_arguments(arguments) do
    case JSON.decode(arguments) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end
end

defmodule DshBeam.Agent.Loop.Projection do
  @moduledoc """
  The session log → model-message projection (the reference's
  `deriveMessages`): every model-visible event in append order becomes exactly
  one OpenAI-compatible message.

  The projection is the ONLY place that reads the session for the model, so a
  turn replays identically across requests and across runs — the same prefix
  in, the same prompt-cache hit out. Tool turns are preserved: a consecutive
  run of `tool_call` events becomes one assistant `tool_calls` message, and
  each `tool_result` becomes the `tool` message that followed it, instead of
  being dropped. So a later turn sees what it actually did, and the prefix
  does not shift between the last tool run and the next user turn.

  Round-trip guarantee: a run that ends in a tool call appends exactly the
  tool_call/tool_result events for that call, and projecting them back yields
  exactly the assistant tool_calls + tool messages that were sent. The UI's
  display projection stays independent (it reads the raw event shapes).
  """

  @doc "Project the session log to model messages, in append order."
  def from_session(session) do
    case DshBeam.Session.all(session) do
      events when is_list(events) ->
        events
        |> Enum.reduce(%{messages: [], open: nil}, fn event, acc -> step(acc, event) end)
        |> close_open()
        |> Map.fetch!(:messages)
        |> Enum.reverse()

      _ ->
        []
    end
  end

  # -- state: messages (accumulated in reverse) + open (the live assistant
  #    tool-call turn: its calls and the tool messages that follow it) --

  defp step(acc, %{"role" => "user", "content" => content}),
    do: push(acc, %{"role" => "user", "content" => content})

  defp step(acc, %{"role" => "assistant", "content" => content}),
    do: push(acc, %{"role" => "assistant", "content" => content})

  defp step(acc, %{"role" => "tool_call"} = event),
    do: add_call(acc, event)

  defp step(acc, %{"role" => "tool_result"} = event),
    do: add_result(acc, event)

  defp step(acc, _event), do: acc

  # a new non-tool message closes any open tool-call turn first, so the
  # assistant tool_calls message precedes its tool messages in the output
  defp push(%{open: nil} = acc, message), do: %{acc | messages: [message | acc.messages]}

  defp push(acc, message) do
    acc = close_open(acc)
    %{acc | messages: [message | acc.messages]}
  end

  defp add_call(%{open: nil} = acc, event), do: %{acc | open: %{calls: [call(event)], tools: []}}

  defp add_call(acc, event) do
    open = %{acc.open | calls: [call(event) | acc.open.calls]}
    %{acc | open: open}
  end

  defp add_result(%{open: %{calls: [_ | _]}} = acc, event) do
    message = %{
      "role" => "tool",
      "tool_call_id" => event["tool_call_id"] || hd(acc.open.calls)["id"],
      "content" => event["content"]
    }

    %{acc | open: %{acc.open | tools: [message | acc.open.tools]}}
  end

  defp add_result(acc, _event), do: acc

  defp close_open(%{open: nil} = acc), do: acc

  defp close_open(%{open: %{calls: calls, tools: tools}, messages: messages} = acc) do
    tool_calls_message = %{
      "role" => "assistant",
      "content" => "",
      "tool_calls" => Enum.reverse(calls)
    }

    %{acc | open: nil, messages: Enum.reverse(tools) ++ [tool_calls_message | messages]}
  end

  defp call(event) do
    %{
      "id" => event["id"] || "call_0",
      "type" => "function",
      "function" => %{
        "name" => event["name"],
        "arguments" => event["arguments_json"] || JSON.encode!(event["arguments"] || %{})
      }
    }
  end
end
