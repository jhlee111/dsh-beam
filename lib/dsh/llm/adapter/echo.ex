defmodule DshBeam.Llm.Adapter.Echo do
  @moduledoc """
  An offline demo adapter: the model answers with the echoed last message.
  Lets the console (and tests) run the full chat loop without credentials or
  a network.
  """

  @behaviour DshBeam.Llm.Adapter

  @impl true
  def complete(_config, []) do
    {:ok, "echo: (no messages)"}
  end

  def complete(_config, messages) do
    {:ok, "echo: " <> List.last(messages)["content"]}
  end
end
