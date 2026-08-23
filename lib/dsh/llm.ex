defmodule DshBeam.Llm do
  @moduledoc """
  The LLM capability: chat/2 completes messages through the :llm binding;
  configure/2 updates the provider's connection facts for the next request
  without re-mounting; config/1 reads them back.
  """

  @typedoc "One chat message: role and content."
  @type message :: %{required(String.t()) => String.t()}

  @typedoc "A full completion: content, tool calls, and finish reason."
  @type result :: %{
          content: String.t() | nil,
          tool_calls: [DshBeam.Llm.Adapter.tool_call()],
          finish_reason: atom() | {:error, atom()}
        }

  @doc "Complete messages. Returns {:ok, content} (the visible text)."
  @spec chat(pid(), [message()]) :: {:ok, String.t()} | {:error, term()}
  def chat(llm, messages) when is_pid(llm) and is_list(messages) do
    case :gen_statem.call(llm, {:chat, messages}) do
      {:ok, %{content: content}} -> {:ok, content}
      other -> other
    end
  end

  @doc "Complete messages with options (:tools). Returns the full completion."
  @spec chat(pid(), [message()], keyword()) :: {:ok, result()} | {:error, term()}
  def chat(llm, messages, opts) when is_pid(llm) and is_list(messages) and is_list(opts) do
    :gen_statem.call(llm, {:chat, messages, opts})
  end

  @doc "Update connection facts (model, endpoint, credential). Returns :ok."
  @spec configure(pid(), keyword()) :: :ok
  def configure(llm, opts) when is_pid(llm) and is_list(opts) do
    :gen_statem.call(llm, {:configure, opts})
  end

  @doc "The provider's current connection config."
  @spec config(pid()) :: map()
  def config(llm) when is_pid(llm) do
    :gen_statem.call(llm, :config)
  end
end
