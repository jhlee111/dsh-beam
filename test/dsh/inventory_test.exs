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

  test "a saved setting override reaches the running plugin's mount config" do
    {:ok, runtime} = DshBeam.Runtime.start_link([], [])
    store = DshBeam.Runtime.settings(runtime)
    entry = %{id: :sample, plugin: InventorySample, config: [], disabled: false}

    # no override yet: the mount config carries the declared default
    :ok = DshBeam.Runtime.reconcile(runtime, [entry])
    assert {:ok, 60_000} = Keyword.fetch(loop_config(runtime, :sample), :command_timeout_ms)

    # put the override, then mount a FRESH entry (e.g. after a restart): the
    # resolved setting is baked into the mount config
    :ok = DshBeam.Settings.put(store, InventorySample, :command_timeout_ms, 999)
    :ok = DshBeam.Runtime.reconcile(runtime, [])

    :ok = DshBeam.Runtime.reconcile(runtime, [entry])
    assert {:ok, 999} = Keyword.fetch(loop_config(runtime, :sample), :command_timeout_ms)
  end

  test "restart/2 re-mounts with the updated settings override" do
    {:ok, runtime} = DshBeam.Runtime.start_link([], [])
    store = DshBeam.Runtime.settings(runtime)
    entry = %{id: :sample, plugin: InventorySample, config: [], disabled: false}

    :ok = DshBeam.Runtime.reconcile(runtime, [entry])
    assert {:ok, 60_000} = Keyword.fetch(loop_config(runtime, :sample), :command_timeout_ms)

    # save an override and restart the live plugin: the config picks it up
    :ok = DshBeam.Settings.put(store, InventorySample, :command_timeout_ms, 4242)
    :ok = DshBeam.Runtime.restart(runtime, :sample)

    assert {:ok, 4242} = Keyword.fetch(loop_config(runtime, :sample), :command_timeout_ms)
  end

  defp loop_config(runtime, _id) do
    %{sample: rec} = DshBeam.Runtime.entries(runtime)
    {_, %{config: config}} = :sys.get_state(rec.pid)
    config
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
