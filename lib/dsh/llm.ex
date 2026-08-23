defmodule DshBeam.Llm do
  @moduledoc """
  The LLM capability: chat/2 asks the :llm binding (a DshBeam.Llm.Plugin
  fiber) to complete a message list.
  """

  @typedoc "One chat message: role and content."
  @type message :: %{required(String.t()) => String.t()}

  @doc "Complete messages through the LLM provider fiber. Returns {:ok, content}."
  @spec chat(pid(), [message()]) :: {:ok, String.t()} | {:error, term()}
  def chat(llm, messages) when is_pid(llm) and is_list(messages) do
    :gen_statem.call(llm, {:chat, messages})
  end
end
