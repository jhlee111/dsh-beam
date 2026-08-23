defmodule DshBeam.Ui.Registry do
  @moduledoc """
  The installed-UI-slot catalog — the harness's ui-slots SlotRegistry, in
  Elixir. Every `slot` declared by a loaded plugin is a registered UI
  contribution; the console (or any LiveView) composes them per slot key.

  A slot's `component` is a function component — `{M, :fun, []}` or a
  1-arity fun — invoked as `component.(assigns)`. Plugins declare the slot;
  the host renders it; the two never meet at compile time.
  """

  @typedoc "One registered slot: its key, kind, scope, component, and order."
  @type entry :: %{
          name: atom(),
          kind: atom(),
          scope: atom(),
          component: term(),
          order: integer(),
          key: term(),
          select: term(),
          plugin: module()
        }

  @doc "Every registered slot, sorted by (name, order)."
  @spec installed() :: [entry()]
  def installed do
    entries =
      for inventory_entry <- DshBeam.Plugin.Inventory.installed(),
          slot <- DshBeam.Plugin.slots(inventory_entry.plugin),
          do: %{
            name: slot.name,
            kind: slot.kind,
            scope: slot.scope,
            component: slot.component,
            order: slot.order,
            key: slot.key,
            select: slot.select,
            plugin: inventory_entry.plugin
          }

    Enum.sort_by(entries, &{&1.name, &1.order})
  end

  @doc "All registrations for one slot key."
  @spec for_slot(atom()) :: [entry()]
  def for_slot(name) do
    installed() |> Enum.filter(&(&1.name == name))
  end
end
