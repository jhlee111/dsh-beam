defmodule DshBeam.Llm.Adapter do
  @moduledoc """
  The HTTP boundary of an LLM provider. complete/2 turns a chat-completion
  request into the model's reply text.

  The adapter is swappable per configuration — the provider-swap pattern of
  milestone 1: production mounts DshBeam.Llm.Adapter.Req (OpenAI-compatible
  APIs such as DeepSeek), tests inject a stub so the whole pipeline runs
  offline.
  """

  @typedoc "Adapter configuration: endpoint, credentials, model, plus extras."
  @type config :: %{
          required(:base_url) => String.t(),
          required(:api_key) => String.t(),
          required(:model) => String.t(),
          optional(term()) => term()
        }

  @typedoc "One chat message: role and content (JSON-safe)."
  @type message :: %{required(String.t()) => String.t()}

  @callback complete(config(), [message()]) :: {:ok, String.t()} | {:error, term()}
end
