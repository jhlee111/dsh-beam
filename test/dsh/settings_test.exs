defmodule DshBeam.SettingsTest do
  use ExUnit.Case, async: false

  setup do
    {:ok, store} = DshBeam.Settings.start_link()
    %{store: store}
  end

  test "resolves the declared default when no override exists", %{store: store} do
    assert {:ok, 60_000} = DshBeam.Settings.get(store, SettingsSample, :command_timeout_ms)
  end

  test "an override wins and is reflected in all/2", %{store: store} do
    assert :ok = DshBeam.Settings.put(store, SettingsSample, :command_timeout_ms, 1234)
    assert {:ok, 1234} = DshBeam.Settings.get(store, SettingsSample, :command_timeout_ms)

    assert DshBeam.Settings.all(store, SettingsSample)[:command_timeout_ms] == 1234
  end

  test "an invalid value is rejected without changing the setting", %{store: store} do
    assert {:error, :invalid_value} =
             DshBeam.Settings.put(store, SettingsSample, :command_timeout_ms, "nope")

    assert {:ok, 60_000} = DshBeam.Settings.get(store, SettingsSample, :command_timeout_ms)
  end

  test "unknown settings are reported", %{store: store} do
    assert :not_found = DshBeam.Settings.get(store, SettingsSample, :no_such_setting)
    assert :not_found = DshBeam.Settings.put(store, SettingsSample, :no_such_setting, 1)
  end

  test "a credential setting holds a reference, never a literal key", %{store: store} do
    assert :ok = DshBeam.Settings.put(store, SettingsSample, :api_key, {:env, "MY_KEY"})
    assert {:ok, {:env, "MY_KEY"}} = DshBeam.Settings.get(store, SettingsSample, :api_key)

    # a bare literal is not a configuration value — it is rejected
    assert {:error, :invalid_value} =
             DshBeam.Settings.put(store, SettingsSample, :api_key, "sk-bare")
  end
end

defmodule SettingsSample do
  @moduledoc false
  use DshBeam.Plugin

  setting(:command_timeout_ms, type: :integer, default: 60_000, doc: "command timeout")

  setting(:api_key,
    type: :credential,
    default: {:env, "DEEPSEEK_API_KEY"},
    doc: "provider credential reference"
  )
end
