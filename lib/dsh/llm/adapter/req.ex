defmodule DshBeam.Llm.Adapter.Req do
  @moduledoc """
  A minimal OpenAI-compatible adapter: POST /chat/completions (non-streaming).
  The LLM provider is an EXAMPLE of the "everything is a plugin" design, not a
  client framework, so this adapter stays intentionally thin: transport-only,
  resolving the credential reference on every request.
  """

  @behaviour DshBeam.Llm.Adapter

  @impl true
  def complete(config, messages) do
    with {:ok, api_key} <- DshBeam.Credential.resolve(config.credential) do
      post(config, messages, api_key)
    end
  end

  defp post(config, messages, api_key) do
    url = String.trim_trailing(config.base_url, "/") <> "/chat/completions"

    body = %{model: config.model, messages: messages, stream: false}

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

  defp parse(%{"choices" => [%{"message" => %{"content" => content}} | _]})
       when is_binary(content) do
    {:ok, content}
  end

  defp parse(other), do: {:error, {:unexpected_response, other}}
end
