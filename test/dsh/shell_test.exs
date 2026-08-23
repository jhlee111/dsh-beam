defmodule DshBeam.ShellTest do
  use ExUnit.Case, async: false

  defp shell_entry(opts) do
    %{id: :shell, plugin: DshBeam.Shell.Plugin, config: opts, disabled: false}
  end

  test "the shell plugin provides :shell with its typed settings schema" do
    settings = DshBeam.Plugin.settings(DshBeam.Shell.Plugin)
    assert Enum.any?(settings, &(&1.name == :command_timeout_ms and &1.type == :integer))
    assert Enum.any?(settings, &(&1.name == :output_cap_bytes and &1.type == :integer))

    # the inventory catalog lists it (it is a plugin like any other)
    entry = Enum.find(DshBeam.Plugin.Inventory.installed(), &(&1.plugin == DshBeam.Shell.Plugin))
    assert entry != nil
  end

  test "run/3 executes a command and returns its output" do
    {:ok, runtime} = DshBeam.Runtime.start_link([shell_entry([])], [])
    ctx = DshBeam.Runtime.context(runtime)

    {:ok, shell} = DshBeam.Context.get(ctx, :shell)
    assert {:ok, "hi\n"} = DshBeam.Shell.Plugin.run(shell, "echo", ["hi"])
  end

  test "output is capped at the configured limit" do
    {:ok, runtime} = DshBeam.Runtime.start_link([shell_entry(output_cap_bytes: 3)], [])
    ctx = DshBeam.Runtime.context(runtime)

    {:ok, shell} = DshBeam.Context.get(ctx, :shell)
    assert {:ok, "abc"} = DshBeam.Shell.Plugin.run(shell, "echo", ["abcdef"])
  end

  test "a non-zero exit is reported with its status and output" do
    {:ok, runtime} = DshBeam.Runtime.start_link([shell_entry([])], [])
    ctx = DshBeam.Runtime.context(runtime)

    {:ok, shell} = DshBeam.Context.get(ctx, :shell)

    assert {:error, {:exit_status, 3}, "boom\n"} =
             DshBeam.Shell.Plugin.run(shell, "sh", ["-c", "echo boom; exit 3"])
  end

  test "a command exceeding the timeout is terminated" do
    {:ok, runtime} = DshBeam.Runtime.start_link([shell_entry(command_timeout_ms: 100)], [])
    ctx = DshBeam.Runtime.context(runtime)

    {:ok, shell} = DshBeam.Context.get(ctx, :shell)
    assert {:error, :timeout, ""} = DshBeam.Shell.Plugin.run(shell, "sleep", ["2"])
  end

  test "removing :shell deactivates the consumer first (the guard)" do
    consumer = %{
      id: :shc,
      plugin: DshBeam.Shell.Consumer,
      config: [command: "echo", args: ["from-consumer"], parent: self()],
      disabled: false
    }

    {:ok, runtime} = DshBeam.Runtime.start_link([shell_entry([]), consumer], [])
    ctx = DshBeam.Runtime.context(runtime)

    assert_receive {:shell_consumer_active, shc}, 2000

    assert {:ok, "from-consumer\n"} = DshBeam.Shell.Consumer.run(shc)

    :ok = DshBeam.Runtime.reconcile(runtime, [consumer])

    history = DshBeam.Context.history(ctx)
    deactivated = Enum.find_index(history, &match?({:deactivated, pid} when pid == shc, &1))
    unloaded = Enum.find_index(history, &match?({:unloaded, _pid}, &1))
    assert deactivated != nil and unloaded != nil and deactivated < unloaded

    assert DshBeam.Context.get(ctx, :shell) == :not_found
    assert DshBeam.Plugin.fiber_state(shc) == :inactive
  end
end
