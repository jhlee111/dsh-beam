defmodule DshBeam.Llm.Plugin do
  @moduledoc """
  The LLM capability provider: mounts an OpenAI-compatible chat-completion
  endpoint (DeepSeek and peers) and provides it under :llm.

  The API connection itself is a fiber — killing it deactivates every
  dependent (chat consumers) through the L-Unload guard before the binding
  withdraws, and re-injection brings them back.

  Config:

  - :base_url — endpoint origin, default "https://api.deepseek.com"
  - :api_key — bearer key; falls back to the DEEPSEEK_API_KEY environment
  - :model — default "deepseek-chat"
  - :adapter — DshBeam.Llm.Adapter implementation, default
    DshBeam.Llm.Adapter.Req (stub it in tests)
  - :adapter_config — extra fields merged into the adapter config
  """

  use DshBeam.Plugin

  @impl DshBeam.Plugin
  def mount(_ctx, opts) do
    base_url = Keyword.get(opts, :base_url, "https://api.deepseek.com")
    api_key = Keyword.get(opts, :api_key) || System.get_env("DEEPSEEK_API_KEY") || ""
    model = Keyword.get(opts, :model, "deepseek-chat")
    adapter = Keyword.get(opts, :adapter, DshBeam.Llm.Adapter.Req)

    config =
      Map.merge(
        %{base_url: base_url, api_key: api_key, model: model},
        Keyword.get(opts, :adapter_config, %{})
      )

    {:ok, [], %{llm: self()}, %{adapter: adapter, config: config}}
  end

  @impl true
  def handle_event({:call, from}, {:chat, messages}, _state, data) do
    result = data.extra.adapter.complete(data.extra.config, messages)
    {:keep_state_and_data, [{:reply, from, result}]}
  end
end
