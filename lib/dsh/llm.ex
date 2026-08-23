defmodule DshBeam.Llm do
  @moduledoc """
  The LLM capability: chat/2 completes messages through the :llm binding;
  configure/2 updates the provider's connection facts for the next request
  without re-mounting; config/1 reads them back.
  """

  @typedoc "One chat message: role and content."
  @type message :: %{required(String.t()) => String.t()}

  @doc "Complete messages through the LLM provider fiber. Returns {:ok, content}."
  @spec chat(pid(), [message()]) :: {:ok, String.t()} | {:error, term()}
  def chat(llm, messages) when is_pid(llm) and is_list(messages) do
    :gen_statem.call(llm, {:chat, messages})
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
