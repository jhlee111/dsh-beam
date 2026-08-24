defmodule DshBeam.SystemPrompt do
  @moduledoc """
  The assembled system prompt — the reference's `SystemPrompt` registry, for
  dsh-beam. Every plugin can declare `prompt_section` contributions (via the
  DSL); the agent loop assembles the harness identity, a default persona, and
  every plugin's sections (sorted by order) into the model-facing prompt, so a
  plugin tells the model its own role and how to use it.
  """

  @harness_identity %{
    name: :harness_identity,
    order: -100,
    text:
      "You are an AI agent powered by dsh-beam, a plugin-based harness where everything — a tool, a UI panel, a safety guard, a capability — is a plugin."
  }

  @persona %{
    name: :persona,
    order: 0,
    text: "You are a helpful agent. Use tools when needed."
  }

  @doc "Every prompt section (identity + persona + plugin contributions), sorted by order."
  def sections do
    [@harness_identity, @persona | plugin_sections()]
    |> Enum.sort_by(& &1.order)
  end

  @doc "The rendered system prompt: sections joined by blank lines."
  def render do
    sections()
    |> Enum.map(& &1.text)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp plugin_sections do
    for entry <- DshBeam.Plugin.Inventory.installed(),
        section <- DshBeam.Plugin.prompt_sections(entry.plugin),
        do: %{name: section.name, order: section.order, text: section.text}
  end
end
