defmodule DshBeam.Llm.Adapter do
  @moduledoc """
  The transport-only boundary of an LLM provider. complete/3 turns a
  chat-completion request into the model's reply: the visible text, any
  tool calls, and the finish reason (the minimal OpenAI-compatible wire
  vocabulary an agent loop needs to dispatch tools).

  The adapter is swappable per configuration — the provider-swap pattern of
  milestone 1. Connection facts ride the config and the credential reference
  is resolved per request, so a configuration change reaches the next request
  without re-registration.
  """

  @typedoc """
  Connection config: endpoint, credential reference, model, plus
  adapter-specific extras.
  """
  @type config :: %{
          required(:base_url) => String.t(),
          required(:credential) => DshBeam.Credential.ref(),
          required(:model) => String.t(),
          optional(term()) => term()
        }

  @typedoc "One chat message: role and content (JSON-safe)."
  @type message :: %{required(String.t()) => String.t()}

  @typedoc "One model-issued tool call (arguments is the raw JSON string)."
  @type tool_call :: %{id: String.t(), name: String.t(), arguments: String.t()}

  @typedoc "A completed reply: content, tool calls, and finish reason."
  @type result :: %{
          content: String.t() | nil,
          tool_calls: [tool_call()],
          finish_reason: atom() | {:error, atom()}
        }

  @callback complete(config(), [message()], map()) :: {:ok, result()} | {:error, term()}
end
