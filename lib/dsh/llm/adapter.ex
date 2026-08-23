defmodule DshBeam.Llm.Adapter do
  @moduledoc """
  The transport-only boundary of an LLM provider. complete/3 turns a
  chat-completion request into the model's reply: the visible text, any
  tool calls, the finish reason, and usage (the minimal OpenAI-compatible wire
  vocabulary an agent loop needs to dispatch tools).

  An adapter is a PLUGIN (ADR-0015): `use DshBeam.Llm.Adapter` makes the module
  both `use DshBeam.Plugin` (providing `:llm_adapter`) and `@behaviour
  DshBeam.Llm.Adapter` (implementing `complete/3`). The provider resolves the
  adapter capability from the context, so adapter swapping is plugin swapping.
  """

  defmacro __using__(_opts) do
    quote do
      use DshBeam.Plugin

      @behaviour DshBeam.Llm.Adapter

      @impl DshBeam.Plugin
      def mount(_ctx, opts) do
        {:ok, [], %{llm_adapter: self()}, %{adapter_config: Map.new(opts)}}
      end

      @impl true
      def handle_event({:call, from}, {:complete, config, messages, opts}, _state, data) do
        config = Map.merge(config, data.extra.adapter_config)
        {:keep_state_and_data, [{:reply, from, complete(config, messages, opts)}]}
      end
    end
  end

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

  @typedoc "Disjoint token usage for one call (cache counts are separate)."
  @type usage :: %{
          required(:input_tokens) => integer(),
          required(:output_tokens) => integer(),
          optional(:cache_read_tokens) => integer() | nil,
          optional(:cache_write_tokens) => integer() | nil,
          optional(:reasoning_tokens) => integer() | nil
        }

  @typedoc "A completed reply: content, tool calls, finish reason, and usage."
  @type result :: %{
          content: String.t() | nil,
          tool_calls: [tool_call()],
          finish_reason: atom() | {:error, atom()},
          usage: usage() | nil
        }

  @callback complete(config(), [message()], map()) :: {:ok, result()} | {:error, term()}
end
