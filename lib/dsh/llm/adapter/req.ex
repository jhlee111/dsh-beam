defmodule DshBeam.Llm.Adapter.Req do
  @moduledoc """
  The real adapter: an OpenAI-compatible POST /chat/completions (non-streaming)
  via Req. Works with api.deepseek.com (deepseek-chat) and peers.
  """

  @behaviour DshBeam.Llm.Adapter

  @impl true
  def complete(config, messages) do
    url = String.trim_trailing(config.base_url, "/") <> "/chat/completions"

    body = %{
      model: config.model,
      messages: messages,
      stream: false
    }

    headers = [
      {"authorization", "Bearer " <> config.api_key},
      {"content-type", "application/json"}
    ]

    options = [json: body, headers: headers, receive_timeout: 120_000]

    # A :plug in the adapter config replaces the transport (Req.Test.json):
    # the HTTP layer is the mock boundary for offline tests.
    options =
      if plug = Map.get(config, :plug), do: Keyword.put(options, :plug, plug), else: options

    case Req.post(url, options) do
      {:ok, %{status: 200} = response} ->
        parse(response.body)

      {:ok, %{status: status, body: response_body}} ->
        {:error, {:http_error, status, response_body}}

      {:error, reason} ->
        {:error, {:http_error, reason}}
    end
  end

  defp parse(%{"choices" => [%{"message" => %{"content" => content}} | _]})
       when is_binary(content) do
    {:ok, content}
  end

  defp parse(other), do: {:error, {:unexpected_response, other}}
end
