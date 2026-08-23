defmodule DshBeam.Llm.Adapter do
  @moduledoc """
  The transport-only boundary of an LLM provider. complete/2 turns a
  chat-completion request into the model's reply text.

  The adapter is swappable per configuration — the provider-swap pattern of
  milestone 1: production mounts DshBeam.Llm.Adapter.Req, tests inject a stub
  so the whole pipeline runs offline. Connection facts ride the config and
  the credential reference is resolved per request, so a configuration change
  reaches the next request without re-registration.
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

  @callback complete(config(), [message()]) :: {:ok, String.t()} | {:error, term()}
end
