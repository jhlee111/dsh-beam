defmodule DshBeam.Llm.Plugin do
  @moduledoc """
  The LLM capability provider — an example of the "everything is a plugin"
  design, not a client framework. It provides :llm and owns the connection
  facts (endpoint, model, credential reference).

  The ADAPTER is a plugin too (ADR-0015): a `DshBeam.Llm.Adapter` implementation
  that also `use DshBeam.Plugin` and provides `:llm_adapter`. This provider
  resolves that capability from the context, so swapping adapters is swapping a
  plugin, not changing a config atom.

  The adapter resolves the credential reference per request, so configure/2
  changes the provider's model, endpoint, or credential for the next request
  WITHOUT re-mounting the fiber — dynamic reconfiguration, the
  spatiotemporal-composition principle.

  Config (mount and configure accept the same keys):

  - :base_url — endpoint origin, default "https://api.deepseek.com"
  - :model — default "deepseek-chat"
  - :credential — a DshBeam.Credential reference, default
    {:env, "DEEPSEEK_API_KEY"} (a literal key is not a configuration value)
  - :adapter_config — extra fields merged into the adapter's config
  """

  use DshBeam.Plugin

  need(:llm_adapter)

  # Typed settings: persisted in the settings store, so the model/endpoint/
  # credential the Models surface saves are durable across restarts. The
  # runtime layers these overrides under the entry config at mount, and
  # configure/2 still re-arms them in-memory for the next request.
  setting(:model,
    type: :string,
    default: "deepseek-chat",
    doc: "The chat model (e.g. deepseek-chat, deepseek-reasoner)"
  )

  setting(:base_url,
    type: :string,
    default: "https://api.deepseek.com",
    doc: "The OpenAI-compatible chat/completions endpoint origin"
  )

  setting(:credential,
    type: :credential,
    default: {:env, "DEEPSEEK_API_KEY"},
    doc: "The credential reference: env:VAR_NAME or literal:the-key"
  )

  @impl DshBeam.Plugin
  def mount(_ctx, opts) do
    {:ok, [:llm_adapter], %{llm: self()}, %{config: default_config(opts)}}
  end

  @impl true
  def handle_event({:call, from}, {:chat, messages}, _state, data) do
    {:keep_state_and_data, [{:reply, from, do_chat(data, messages, %{})}]}
  end

  def handle_event({:call, from}, {:chat, messages, opts}, _state, data) do
    {:keep_state_and_data, [{:reply, from, do_chat(data, messages, opts)}]}
  end

  def handle_event({:call, from}, {:configure, opts}, _state, data) do
    config = merge_config(data.extra.config, opts)
    new_data = %{data | extra: %{data.extra | config: config}}
    {:keep_state, new_data, [{:reply, from, :ok}]}
  end

  def handle_event({:call, from}, :config, _state, data) do
    {:keep_state_and_data, [{:reply, from, data.extra.config}]}
  end

  defp do_chat(data, messages, opts) do
    case DshBeam.Context.resolve(data.ctx) do
      {:active, %{llm_adapter: adapter}} ->
        # the adapter sees connection facts + flattened adapter_config (so extras
        # like a :plug ride the top level), never the registry fields
        adapter_config =
          data.extra.config
          |> Map.take([:base_url, :model, :credential])
          |> Map.merge(data.extra.config.adapter_config)

        :gen_statem.call(adapter, {:complete, adapter_config, messages, opts})

      _ ->
        {:error, :adapter_unavailable}
    end
  end

  defp default_config(opts) do
    %{
      base_url: Keyword.get(opts, :base_url, "https://api.deepseek.com"),
      model: Keyword.get(opts, :model, "deepseek-chat"),
      credential: Keyword.get(opts, :credential, {:env, "DEEPSEEK_API_KEY"}),
      adapter_config: Keyword.get(opts, :adapter_config, %{})
    }
  end

  defp merge_config(config, opts) do
    Enum.reduce(opts, config, fn
      {:base_url, value}, acc when is_binary(value) -> %{acc | base_url: value}
      {:model, value}, acc when is_binary(value) -> %{acc | model: value}
      {:credential, value}, acc -> %{acc | credential: value}
      {:adapter_config, value}, acc when is_map(value) -> %{acc | adapter_config: value}
      _ignored, acc -> acc
    end)
  end
end
