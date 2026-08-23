defmodule DshBeam.Tool.Registry do
  @moduledoc """
  The installed-tool catalog: every tool declared by a loaded plugin — the
  original harness's tool registry, i.e. the model-facing tool list an agent
  loop sends to the LLM.
  """

  @typedoc "A registry entry: the tool spec plus its owning plugin."
  @type entry :: %{name: atom(), description: String.t(), parameters: map(), plugin: module()}

  @doc "Every installed tool, sorted by name."
  @spec installed() :: [entry()]
  def installed do
    entries =
      for inventory_entry <- DshBeam.Plugin.Inventory.installed(),
          tool <- DshBeam.Plugin.tools(inventory_entry.plugin),
          do: %{
            name: tool.name,
            description: tool.description,
            parameters: tool.parameters,
            plugin: inventory_entry.plugin
          }

    Enum.sort_by(entries, & &1.name)
  end
end
