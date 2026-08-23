defmodule DshBeam.Llm.Adapter.Req do
  @moduledoc """
  A minimal OpenAI-compatible adapter: POST /chat/completions (non-streaming).
  The LLM provider is an EXAMPLE of the "everything is a plugin" design, not a
  client framework, so this adapter stays thin: it forwards `tools` and parses
  content, tool_calls, and finish_reason — the vocabulary an agent loop needs.
  """

  @behaviour DshBeam.Llm.Adapter

  @impl true
  def complete(config, messages, opts) do
    with {:ok, api_key} <- DshBeam.Credential.resolve(config.credential) do
      post(config, messages, api_key, opts)
    end
  end

  defp post(config, messages, api_key, opts) do
    url = String.trim_trailing(config.base_url, "/") <> "/chat/completions"

    body = %{model: config.model, messages: messages, stream: false}
    tools = opts[:tools]
    body = if tools in [nil, []], do: body, else: Map.put(body, :tools, tools)

    headers = [
      {"authorization", "Bearer " <> api_key},
      {"content-type", "application/json"}
    ]

    options = [json: body, headers: headers, receive_timeout: 120_000]

    # A :plug in the adapter config replaces the transport (Req.Test.json):
    # the HTTP layer is the mock boundary for offline tests.
    options =
      if plug = Map.get(config, :plug), do: Keyword.put(options, :plug, plug), else: options

    case Req.post(url, options) do
      {:ok, %{status: 200, body: response_body}} -> parse(response_body)
      {:ok, %{status: status, body: response_body}} -> {:error, {:http, status, response_body}}
      {:error, reason} -> {:error, {:http_error, reason}}
    end
  end

  defp parse(%{"choices" => [choice | _]}) do
    message = choice["message"] || %{}

    {:ok,
     %{
       content: message["content"],
       tool_calls: parse_tool_calls(message["tool_calls"]),
       finish_reason: map_finish_reason(choice["finish_reason"])
     }}
  end

  defp parse(other), do: {:error, {:unexpected_response, other}}

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
end
