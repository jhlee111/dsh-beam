defmodule DshBeam.Llm.Plugin do
  @moduledoc """
  The LLM capability provider — an example of the "everything is a plugin"
  design, not a client framework. It provides :llm and owns the connection
  facts (endpoint, model, credential reference, adapter).

  The adapter is transport-only and resolves the credential reference per
  request, so configure/2 changes the provider's model, endpoint, or
  credential for the next request WITHOUT re-mounting the fiber — dynamic
  reconfiguration, the spatiotemporal-composition principle.

  Config (mount and configure accept the same keys):

  - :base_url — endpoint origin, default "https://api.deepseek.com"
  - :model — default "deepseek-chat"
  - :credential — a DshBeam.Credential reference, default
    {:env, "DEEPSEEK_API_KEY"} (a literal key is not a configuration value)
  - :adapter — DshBeam.Llm.Adapter implementation, default
    DshBeam.Llm.Adapter.Req
  - :adapter_config — extra fields merged into the adapter's config
  """

  use DshBeam.Plugin

  @impl DshBeam.Plugin
  def mount(_ctx, opts) do
    {:ok, [], %{llm: self()}, %{config: default_config(opts)}}
  end

  @impl true
  def handle_event({:call, from}, {:chat, messages}, _state, data) do
    # the adapter sees connection facts + flattened adapter_config (so extras
    # like a :plug or a stub's :parent ride the top level), never the registry
    # fields (:adapter, :adapter_config)
    adapter_config =
      data.extra.config
      |> Map.take([:base_url, :model, :credential])
      |> Map.merge(data.extra.config.adapter_config)

    result = data.extra.config.adapter.complete(adapter_config, messages)
    {:keep_state_and_data, [{:reply, from, result}]}
  end

  def handle_event({:call, from}, {:configure, opts}, _state, data) do
    config = merge_config(data.extra.config, opts)
    new_data = %{data | extra: %{data.extra | config: config}}
    {:keep_state, new_data, [{:reply, from, :ok}]}
  end

  def handle_event({:call, from}, :config, _state, data) do
    {:keep_state_and_data, [{:reply, from, data.extra.config}]}
  end

  defp default_config(opts) do
    %{
      base_url: Keyword.get(opts, :base_url, "https://api.deepseek.com"),
      model: Keyword.get(opts, :model, "deepseek-chat"),
      credential: Keyword.get(opts, :credential, {:env, "DEEPSEEK_API_KEY"}),
      adapter: Keyword.get(opts, :adapter, DshBeam.Llm.Adapter.Req),
      adapter_config: Keyword.get(opts, :adapter_config, %{})
    }
  end

  defp merge_config(config, opts) do
    Enum.reduce(opts, config, fn
      {:base_url, value}, acc when is_binary(value) -> %{acc | base_url: value}
      {:model, value}, acc when is_binary(value) -> %{acc | model: value}
      {:credential, value}, acc -> %{acc | credential: value}
      {:adapter, value}, acc when is_atom(value) -> %{acc | adapter: value}
      {:adapter_config, value}, acc when is_map(value) -> %{acc | adapter_config: value}
      _ignored, acc -> acc
    end)
  end
end
