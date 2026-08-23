defmodule DshBeam.Plugin.Inventory do
  @moduledoc """
  The installed-plugin catalog: every loaded module declaring the
  DshBeam.Plugin behaviour, with its settings schema — the original harness's
  "plugin inventory" (list + inspect). Enabled/disabled is a runtime property
  of the composition, not of the installed module; this module answers "what
  is installed and how is each configured".
  """

  @type setting :: %{name: atom(), type: atom(), default: term(), doc: String.t()}
  @type entry :: %{plugin: module(), settings: [setting()]}

  @doc "Every installed plugin module and its settings schema, sorted by name."
  @spec installed() :: [entry()]
  def installed do
    entries =
      for mod <- loaded_plugins(),
          do: %{plugin: mod, settings: DshBeam.Plugin.settings(mod)}

    Enum.sort_by(entries, &inspect(&1.plugin))
  end

  @doc "The settings schema of one installed plugin ([] when absent or not a plugin)."
  @spec settings_for(module()) :: [setting()]
  def settings_for(mod) when is_atom(mod) do
    DshBeam.Plugin.settings(mod)
  end

  defp loaded_plugins do
    for {mod, _binary} <- :code.all_loaded(),
        is_atom(mod),
        behaviours = mod.module_info(:attributes)[:behaviour] || [],
        DshBeam.Plugin in behaviours,
        do: mod
  end
end
