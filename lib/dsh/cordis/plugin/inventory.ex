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

  # Installed plugins are discovered deterministically, not by whatever
  # happens to be loaded at the moment: the application's own compiled modules
  # (Application.spec) plus any runtime-loaded plugin (a creator-defined module
  # compiled with Code.compile_string). Relying on :code.all_loaded() alone
  # made the inventory — and therefore the tool registry, the UI slots, and the
  # plugins panel — depend on load order, so a bare console mounted in a fresh
  # VM rendered no panels until something else had referenced them.
  defp loaded_plugins do
    app_modules = Application.spec(:dsh_beam, :modules) || []
    runtime_modules = for {mod, _binary} <- :code.all_loaded(), do: mod

    (app_modules ++ runtime_modules)
    |> Enum.uniq()
    |> Enum.filter(&plugin?/1)
  end

  defp plugin?(mod) do
    is_atom(mod) and Code.ensure_loaded?(mod) and
      Enum.member?(mod.module_info(:attributes)[:behaviour] || [], DshBeam.Plugin)
  end
end
