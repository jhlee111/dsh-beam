defmodule DshBeam.Llm.Adapter.Echo do
  @moduledoc """
  An offline demo adapter: the model answers with the echoed last message.
  Lets the console (and tests) run the full chat loop without credentials or
  a network.
  """

  @behaviour DshBeam.Llm.Adapter

  @impl true
  def complete(_config, messages, _opts) do
    content =
      case messages do
        [] -> "echo: (no messages)"
        _ -> "echo: " <> List.last(messages)["content"]
      end

    {:ok, %{content: content, tool_calls: [], finish_reason: :stop}}
  end
end
