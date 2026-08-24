defmodule DshBeam.Llm.Adapter.Req do
  @moduledoc """
  A minimal OpenAI-compatible adapter plugin: POST /chat/completions
  (non-streaming). It owns the transport and the wire parsing — content,
  tool_calls, finish_reason, and usage — and PROVIDES the adapter capability
  (`:llm_adapter`) the `DshBeam.Llm.Plugin` provider resolves.

  `use DshBeam.Llm.Adapter` makes this module both a plugin (providing
  `:llm_adapter`) and the transport contract's implementation (ADR-0015).

  The response budget comes from the adapter config's `:receive_timeout` (the
  LLM provider's typed setting, default 120s): a slow reasoning model can be
  given a longer budget without recompiling anything.
  """

  use DshBeam.Llm.Adapter

  @default_receive_timeout 300_000

  @impl true
  def complete(config, messages, opts) do
    with {:ok, api_key} <- DshBeam.Credential.resolve(config.credential) do
      if stream = opts[:stream] do
        stream_post(config, messages, api_key, opts, stream)
      else
        post(config, messages, api_key, opts)
      end
    end
  end

  defp post(config, messages, api_key, opts) do
    url = String.trim_trailing(config.base_url, "/") <> "/chat/completions"

    body = %{model: config.model, messages: messages, stream: false}
    tools = opts[:tools]
    body = if tools in [nil, []], do: body, else: Map.put(body, :tools, tools)

    # A reasoning model forwards its effort level (low/high/max) verbatim;
    # a non-reasoning model omits the field entirely.
    body =
      case Map.get(config, :reasoning_effort) do
        effort when is_binary(effort) and effort != "" -> Map.put(body, :reasoning_effort, effort)
        _ -> body
      end

    headers = [
      {"authorization", "Bearer " <> api_key},
      {"content-type", "application/json"}
    ]

    timeout = Map.get(config, :receive_timeout, @default_receive_timeout)
    options = [json: body, headers: headers, receive_timeout: timeout]

    # A :plug in the adapter config replaces the transport (Req.Test.json):
    # the HTTP layer is the mock boundary for offline tests.
    options =
      if plug = Map.get(config, :plug), do: Keyword.put(options, :plug, plug), else: options

    case opts[:cancel] do
      nil ->
        request(url, options)

      token ->
        # A cooperative cancel token turns the blocking transport into a
        # cancellable worker task: the adapter polls the token while the
        # request runs and brutal-kills the task on cancellation, so a user
        # stop aborts an in-flight model call instead of waiting it out.
        cancellable_request(url, options, token, timeout)
    end
  end

  defp request(url, options) do
    case Req.post(url, options) do
      {:ok, %{status: 200, body: response_body}} -> parse(response_body)
      {:ok, %{status: status, body: response_body}} -> {:error, {:http, status, response_body}}
      {:error, reason} -> {:error, {:http_error, reason}}
    end
  end

  defp cancellable_request(url, options, token, timeout) do
    # The transport runs detached from the adapter fiber: unlinked so a kill
    # (or an unexpected transport crash) never surfaces as a linked-process
    # exit that would tear the adapter down via the default exit hook. The
    # alias monitor behind Task.yield still tracks its result.
    task = Task.async(fn -> Req.post(url, options) end)
    Process.unlink(task.pid)

    poll(
      task,
      token,
      System.monotonic_time(:millisecond) + timeout + 1000,
      &normalize_req/1
    )
  end

  defp poll(task, token, deadline, normalizer) do
    cond do
      DshBeam.Agent.Cancel.cancelled?(token) ->
        Task.shutdown(task, :brutal_kill)
        {:error, :cancelled}

      System.monotonic_time(:millisecond) >= deadline ->
        Task.shutdown(task, :brutal_kill)
        {:error, {:http_error, :timeout}}

      true ->
        case Task.yield(task, 25) do
          # Task.yield wraps the task's own return value, so the Req result
          # (already an {:ok, response} | {:error, reason}) is one level down.
          {:ok, result} -> normalizer.(result)
          {:exit, reason} -> {:error, {:http_error, reason}}
          nil -> poll(task, token, deadline, normalizer)
        end
    end
  end

  defp normalize_req({:ok, %{status: 200, body: response_body}}), do: parse(response_body)

  defp normalize_req({:ok, %{status: status, body: response_body}}),
    do: {:error, {:http, status, response_body}}

  defp normalize_req({:error, reason}), do: {:error, {:http_error, reason}}

  defp parse(%{"choices" => [choice | _]} = response) do
    message = choice["message"] || %{}

    {:ok,
     %{
       content: message["content"],
       # DeepSeek's reasoner returns its chain-of-thought in reasoning_content;
       # captured for the chat "Think" row, never sent back to the model.
       reasoning: message["reasoning_content"],
       tool_calls: parse_tool_calls(message["tool_calls"]),
       finish_reason: map_finish_reason(choice["finish_reason"]),
       usage: map_usage(response["usage"])
     }}
  end

  defp parse(other), do: {:error, {:unexpected_response, other}}

  # -- streaming (SSE) --

  # Stream the response and emit reasoning chunks through `stream` (a fun of
  # arity 1 receiving `{:reasoning, chunk}`) as they arrive, so the chat's
  # "Think" row follows the model's chain-of-thought live. Content/tool-call
  # fragments are accumulated and returned as one completed result, and
  # `reasoning` is nil in the returned result (it was already streamed).
  defp stream_post(config, messages, api_key, opts, stream) do
    url = String.trim_trailing(config.base_url, "/") <> "/chat/completions"

    body = %{model: config.model, messages: messages, stream: true}
    tools = opts[:tools]
    body = if tools in [nil, []], do: body, else: Map.put(body, :tools, tools)
    body = put_reasoning_effort(body, config)
    # The streaming response omits usage unless explicitly requested; the
    # trajectory and the assistant event both need it.
    body = Map.put(body, :stream_options, %{include_usage: true})

    headers = [
      {"authorization", "Bearer " <> api_key},
      {"content-type", "application/json"}
    ]

    timeout = Map.get(config, :receive_timeout, @default_receive_timeout)

    # Req's `into: fun` accumulator is a `{request, response}` tuple (never a
    # map) in BOTH the Finch and Plug transports, and the wrapper matches that
    # 2-tuple on every `:status`/`:headers`/`:trailers` event — so the SSE
    # parse state cannot ride the accumulator. It lives in a separate Agent
    # instead, and the `into` fun just threads the tuple through untouched.
    #
    # The Agent must be UNLINKED: this fiber traps exits (DshBeam.Plugin sets
    # :trap_exit), and a linked Agent's `:normal` shutdown on Agent.stop/1
    # would surface as {:EXIT, _pid, :normal}, which the default
    # handle_dsh_exit/3 turns into {:stop, :normal} — silently killing the
    # adapter after the first streamed reply (the next chat then reports
    # :adapter_unavailable).
    {:ok, state} = Agent.start(fn -> new_stream_acc() end)

    into = fn
      {:data, data}, acc ->
        Agent.update(state, fn s -> emit_sse(data, s, stream) end)
        {:cont, acc}

      _other, acc ->
        {:cont, acc}
    end

    options = [json: body, headers: headers, receive_timeout: timeout, into: into]

    options =
      if plug = Map.get(config, :plug), do: Keyword.put(options, :plug, plug), else: options

    try do
      result =
        case opts[:cancel] do
          nil -> request_stream(url, options)
          token -> cancellable_stream(url, options, token, timeout)
        end

      acc = state |> Agent.get(& &1) |> flush_buffer(stream)

      case result do
        {:ok, :streamed} -> stream_result(acc)
        {:error, reason} -> {:error, reason}
      end
    after
      Agent.stop(state)
    end
  end

  defp put_reasoning_effort(body, config) do
    case Map.get(config, :reasoning_effort) do
      effort when is_binary(effort) and effort != "" -> Map.put(body, :reasoning_effort, effort)
      _ -> body
    end
  end

  defp new_stream_acc do
    %{
      buffer: "",
      reasoning: "",
      content: "",
      tool_calls: %{},
      finish_reason: nil,
      usage: nil
    }
  end

  # The final SSE event is not guaranteed to end in a blank line, so flush the
  # trailing buffered event (if any) before the result is assembled.
  defp flush_buffer(%{buffer: ""} = acc, _stream), do: acc
  defp flush_buffer(acc, stream), do: process_sse_event(acc.buffer, %{acc | buffer: ""}, stream)

  defp request_stream(url, options) do
    case Req.post(url, options) do
      {:ok, %{status: 200}} -> {:ok, :streamed}
      {:ok, %{status: status}} -> {:error, {:http, status, "stream failed"}}
      {:error, reason} -> {:error, {:http_error, reason}}
    end
  end

  defp cancellable_stream(url, options, token, timeout) do
    task = Task.async(fn -> Req.post(url, options) end)
    Process.unlink(task.pid)
    poll(task, token, System.monotonic_time(:millisecond) + timeout + 1000, &stream_req_result/1)
  end

  defp stream_req_result({:ok, %{status: 200}}), do: {:ok, :streamed}
  defp stream_req_result({:ok, %{status: status}}), do: {:error, {:http, status, "stream failed"}}
  defp stream_req_result({:error, reason}), do: {:error, {:http_error, reason}}

  # Buffer raw SSE bytes, normalize line endings, and process every complete
  # `data: {...}\n\n` event; the trailing partial event stays buffered.
  defp emit_sse(data, acc, stream) do
    buffer = (acc.buffer <> data) |> String.replace("\r\n", "\n")
    parts = String.split(buffer, "\n\n")

    {last, complete} =
      case List.pop_at(parts, -1) do
        {last, rest} -> {last, rest}
      end

    acc = Enum.reduce(complete, acc, &process_sse_event(&1, &2, stream))
    %{acc | buffer: last}
  end

  defp process_sse_event(line, acc, stream) do
    # SSE data lines are `data: {...}` (a space after the colon); strip the
    # `data:` prefix defensively (with or without the space) before decoding.
    json = line |> String.trim() |> String.replace_prefix("data:", "") |> String.trim()

    case json do
      "[DONE]" ->
        acc

      "" ->
        acc

      _ ->
        case JSON.decode(json) do
          {:ok, data} -> process_sse_data(data, acc, stream)
          _ -> acc
        end
    end
  end

  defp process_sse_data(data, acc, stream) do
    delta = data |> Map.get("choices", [%{}]) |> hd() |> Map.get("delta", %{})

    acc =
      case delta["reasoning_content"] do
        nil ->
          acc

        reasoning ->
          stream.({:reasoning, reasoning})
          %{acc | reasoning: acc.reasoning <> reasoning}
      end

    acc =
      case delta["content"] do
        nil -> acc
        content -> %{acc | content: acc.content <> content}
      end

    acc = accumulate_tool_calls(acc, delta["tool_calls"])

    choice = data |> Map.get("choices", [%{}]) |> hd()

    case {choice["finish_reason"], data["usage"]} do
      {f, u} when not is_nil(f) and not is_nil(u) -> %{acc | finish_reason: f, usage: u}
      {f, _} when not is_nil(f) -> %{acc | finish_reason: f}
      {_, u} when not is_nil(u) -> %{acc | usage: u}
      _ -> acc
    end
  end

  defp accumulate_tool_calls(acc, nil), do: acc

  defp accumulate_tool_calls(acc, fragments) do
    tool_calls =
      Enum.reduce(fragments, acc.tool_calls, fn fragment, map ->
        index = fragment["index"] || 0
        fn_ = fragment["function"] || %{}
        existing = Map.get(map, index, %{id: nil, name: nil, args: ""})

        updated = %{
          id: existing.id || fragment["id"],
          name: existing.name || fn_["name"],
          args: existing.args <> (fn_["arguments"] || "")
        }

        Map.put(map, index, updated)
      end)

    %{acc | tool_calls: tool_calls}
  end

  defp stream_result(acc) do
    tool_calls =
      acc.tool_calls
      |> Enum.sort_by(fn {index, _} -> index end)
      |> Enum.map(fn {_index, call} ->
        %{id: call.id, name: call.name, arguments: if(call.args == "", do: "{}", else: call.args)}
      end)

    {:ok,
     %{
       content: acc.content,
       # already emitted through the stream callback, so no full block here
       reasoning: nil,
       tool_calls: tool_calls,
       finish_reason: map_finish_reason(acc.finish_reason),
       usage: map_usage(acc.usage)
     }}
  end

  defp parse_tool_calls(nil), do: []

  defp parse_tool_calls(calls) do
    Enum.map(calls, fn call ->
      function = call["function"] || %{}
      %{id: call["id"], name: function["name"], arguments: function["arguments"] || "{}"}
    end)
  end

  defp map_finish_reason(nil), do: :stop
  defp map_finish_reason("stop"), do: :stop
  defp map_finish_reason("tool_calls"), do: :tool_calls
  defp map_finish_reason("length"), do: :max_tokens
  defp map_finish_reason(other), do: {:error, String.upcase(other)}

  # Disjoint usage counts (ADR-0014): DeepSeek's prompt_tokens INCLUDES cache
  # hits, so cache reads are subtracted out of inputTokens; the harness
  # convention reports them separately.
  defp map_usage(nil), do: nil

  defp map_usage(usage) when is_map(usage) do
    cache_read =
      get_in(usage, ["prompt_tokens_details", "cached_tokens"]) ||
        usage["prompt_cache_hit_tokens"]

    reasoning = get_in(usage, ["completion_tokens_details", "reasoning_tokens"])
    prompt = usage["prompt_tokens"] || 0

    %{
      input_tokens: prompt - (cache_read || 0),
      output_tokens: usage["completion_tokens"] || 0,
      cache_read_tokens: cache_read,
      cache_write_tokens: usage["prompt_cache_miss_tokens"],
      reasoning_tokens: reasoning
    }
  end
end
