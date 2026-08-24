defmodule DshBeam.PermissionTest do
  use ExUnit.Case, async: true

  test "ships the three presets with their labels and knob mapping" do
    presets = DshBeam.Permission.presets()

    assert Map.keys(presets) |> Enum.sort() == [
             "danger-full-access",
             "read-only",
             "workspace-write"
           ]

    # the menu order is declaration order, independent of map key ordering
    assert DshBeam.Permission.order() == ["read-only", "workspace-write", "danger-full-access"]

    assert presets["read-only"] == %{
             sandbox: :read_only,
             approval: :ask,
             name: "Read Only",
             description: "Read the workspace without writing changes."
           }

    assert presets["workspace-write"].sandbox == :workspace_write
    assert presets["workspace-write"].approval == :ask
    assert presets["workspace-write"].name == "Workspace Write"

    # the reference hard-overrides the machine name to the product label
    assert presets["danger-full-access"].name == "Full access"
    assert presets["danger-full-access"].approval == :never
  end

  test "apply/2 appends a durable permission_preset event" do
    {:ok, session} = DshBeam.Session.Memory.start([])

    assert {:ok, 1} = DshBeam.Permission.apply(session, "read-only")
    assert {:ok, 2} = DshBeam.Permission.apply(session, "danger-full-access")

    assert [
             %{"role" => "permission_preset", "preset" => "read-only"},
             %{"role" => "permission_preset", "preset" => "danger-full-access"}
           ] = DshBeam.Session.all(session)

    assert {:error, :unknown_preset} = DshBeam.Permission.apply(session, "nope")
  end

  test "current/1 folds the log to the latest preset and defaults before any apply" do
    {:ok, session} = DshBeam.Session.Memory.start([])

    assert DshBeam.Permission.current(session) == "workspace-write"

    :ok = DshBeam.Permission.apply(session, "read-only") |> then(fn {:ok, _} -> :ok end)
    assert DshBeam.Permission.current(session) == "read-only"

    :ok = DshBeam.Permission.apply(session, "danger-full-access") |> then(fn {:ok, _} -> :ok end)
    assert DshBeam.Permission.current(session) == "danger-full-access"
  end

  test "select_for/1 returns the UI-seat value shape" do
    {:ok, session} = DshBeam.Session.Memory.start([])

    value = DshBeam.Permission.select_for(session)
    assert value.current_value == "workspace-write"

    assert Enum.map(value.options, & &1.value) == [
             "read-only",
             "workspace-write",
             "danger-full-access"
           ]

    assert Enum.map(value.options, & &1.name) == ["Read Only", "Workspace Write", "Full access"]
  end

  test "sandbox_mode/1 and approval_policy/1 resolve a preset's knobs" do
    assert DshBeam.Permission.sandbox_mode("read-only") == :read_only
    assert DshBeam.Permission.sandbox_mode("workspace-write") == :workspace_write
    assert DshBeam.Permission.sandbox_mode("danger-full-access") == :danger_full_access

    assert DshBeam.Permission.approval_policy("danger-full-access") == :never
    assert DshBeam.Permission.approval_policy("workspace-write") == :ask

    assert DshBeam.Permission.sandbox_mode("nope") == nil
  end
end
