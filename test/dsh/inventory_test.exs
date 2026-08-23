defmodule DshBeam.Plugin.InventoryTest do
  use ExUnit.Case, async: false

  test "settings/1 introspects a plugin's typed settings" do
    assert DshBeam.Plugin.settings(InventorySample) == [
             %{
               name: :command_timeout_ms,
               type: :integer,
               default: 60_000,
               doc: "How long one command may run"
             },
             %{
               name: :api_key,
               type: :credential,
               default: {:env, "DEEPSEEK_API_KEY"},
               doc: "The provider credential reference"
             }
           ]
  end

  test "settings/1 is empty for a non-plugin module" do
    assert DshBeam.Plugin.settings(Enum) == []
  end

  test "installed/0 lists every plugin with its settings schema" do
    entry = Enum.find(DshBeam.Plugin.Inventory.installed(), &(&1.plugin == InventorySample))
    assert entry != nil

    assert Enum.any?(entry.settings, &(&1.name == :command_timeout_ms))
    assert Enum.any?(entry.settings, &(&1.type == :credential))
  end

  test "declaring settings leaves the default mount (need/provide) intact" do
    {:ok, runtime} = DshBeam.Runtime.start_link([], [])
    entry = %{id: :sample, plugin: InventorySample, config: [], disabled: false}
    :ok = DshBeam.Runtime.reconcile(runtime, [entry])

    ctx = DshBeam.Runtime.context(runtime)
    assert {:ok, 1} = DshBeam.Context.get(ctx, :sample)
  end
end

defmodule InventorySample do
  @moduledoc false
  use DshBeam.Plugin

  provide(:sample, value: 1)

  setting(:command_timeout_ms,
    type: :integer,
    default: 60_000,
    doc: "How long one command may run"
  )

  setting(:api_key,
    type: :credential,
    default: {:env, "DEEPSEEK_API_KEY"},
    doc: "The provider credential reference"
  )
end
