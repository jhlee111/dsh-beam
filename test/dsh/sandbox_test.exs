defmodule DshBeam.SandboxTest do
  use ExUnit.Case, async: false

  @provider """
  defmodule SbxMadeProvider do
    def mount(config) do
      {:ok, [], %{"made" => 42}, %{path: config["path"]}}
    end

    def handle_dsh_ready(state) do
      File.write(state.extra.path, "ready")
      {:ok, state}
    end

    def handle_dsh_withdraw(keys, state) do
      File.write(state.extra.path, "withdraw:" <> Enum.join(keys, ","))
      {:ok, state}
    end
  end
  """

  @consumer """
  defmodule SbxMadeConsumer do
    def mount(config) do
      {:ok, ["alpha"], %{}, %{path: config["path"]}}
    end

    def handle_dsh_activate(view, state) do
      File.write(state.extra.path, "activated:alpha=" <> to_string(view["alpha"]))
      {:ok, state}
    end

    def handle_dsh_withdraw(_keys, state) do
      File.write(state.extra.path, "withdrawn")
      {:ok, state}
    end
  end
  """

  test "untrusted source runs outside the host BEAM and provides through the boundary" do
    {:ok, runtime} = DshBeam.Runtime.start_link([], [])
    ctx = DshBeam.Runtime.context(runtime)

    path = tmp_path()
    on_exit(fn -> File.rm(path) end)

    {:ok, entry} = DshBeam.Sandbox.define(runtime, @provider, config: %{"path" => path})

    # the child compiled, loaded, and ran the source (ready hook wrote a file)
    wait_until(fn -> File.read(path) == {:ok, "ready"} end)

    # the boundary: the source's module was never compiled or loaded on the host
    assert Code.ensure_loaded?(SbxMadeProvider) == false

    consumer_entry = %{
      id: :c,
      plugin: DshBeam.Consumer,
      config: [deps: [:made], parent: self()],
      disabled: false
    }

    :ok = DshBeam.Runtime.reconcile(runtime, [entry, consumer_entry])
    assert_receive {:consumer_registered, :c, consumer, :active, %{made: 42}}, 2000

    # undefine: dependents drain first, then the child's own teardown runs
    :ok = DshBeam.Sandbox.undefine(runtime, entry)

    assert_receive {:consumer_deactivated, :c, ^consumer, [:made], _view}, 2000
    assert File.read(path) == {:ok, "withdraw:made"}
    assert DshBeam.Context.get(ctx, :made) == :not_found
  end

  test "a sandboxed plugin crash withdraws through the guard and is re-injected" do
    {:ok, runtime} = DshBeam.Runtime.start_link([], [])
    ctx = DshBeam.Runtime.context(runtime)

    path = tmp_path()
    on_exit(fn -> File.rm(path) end)

    {:ok, entry} = DshBeam.Sandbox.define(runtime, @provider, config: %{"path" => path})

    consumer_entry = %{
      id: :slow,
      plugin: SbxSlowConsumer,
      config: [deps: [:made], parent: self(), drain_ms: 200],
      disabled: false
    }

    :ok = DshBeam.Runtime.reconcile(runtime, [entry, consumer_entry])
    assert_receive {:slow_registered, slow, :active}, 2000

    %{id: id} = entry
    %{^id => %{pid: adapter}} = DshBeam.Runtime.entries(runtime)
    os_pid_before = DshBeam.Sandbox.Plugin.os_pid(adapter)
    assert is_integer(os_pid_before)

    # a real crash of the child OS process (SIGKILL)
    :ok = DshBeam.Sandbox.Plugin.kill_child(adapter)

    # the dependent drains through the guard before the binding withdraws
    assert_receive {:slow_drained, ^slow, [:made]}, 3000

    # the runtime re-injects a replacement: a fresh adapter with a fresh child
    wait_until(fn ->
      case DshBeam.Runtime.entries(runtime) do
        %{^id => %{pid: pid}} when is_pid(pid) ->
          pid != adapter and DshBeam.Sandbox.Plugin.os_pid(pid) != os_pid_before

        _ ->
          false
      end
    end)

    assert {:ok, 42} = DshBeam.Context.get(ctx, :made)
    wait_until(fn -> DshBeam.Plugin.fiber_state(slow) == :active end)
  end

  test "a sandboxed plugin declares needs and activates against host bindings" do
    {:ok, runtime} = DshBeam.Runtime.start_link([], [])

    host_entry = %{
      id: :alpha,
      plugin: DshBeam.Provider,
      config: [provides: %{alpha: 1}],
      disabled: false
    }

    :ok = DshBeam.Runtime.reconcile(runtime, [host_entry])

    path = tmp_path()
    on_exit(fn -> File.rm(path) end)

    {:ok, entry} = DshBeam.Sandbox.define(runtime, @consumer, config: %{"path" => path})
    assert Code.ensure_loaded?(SbxMadeConsumer) == false

    %{id: id} = entry
    %{^id => %{pid: adapter}} = DshBeam.Runtime.entries(runtime)

    wait_until(fn -> DshBeam.Plugin.fiber_state(adapter) == :active end)
    assert DshBeam.Sandbox.Plugin.view(adapter) == %{alpha: 1}

    # the activation crossed the boundary and ran the child's hook
    wait_until(fn -> File.read(path) == {:ok, "activated:alpha=1"} end)

    # removing the host provider deactivates the sandboxed consumer too
    :ok = DshBeam.Runtime.reconcile(runtime, [entry])

    wait_until(fn -> File.read(path) == {:ok, "withdrawn"} end)
    assert DshBeam.Plugin.fiber_state(adapter) == :inactive
  end

  test "a broken sandbox source fails loudly and mounts nothing" do
    {:ok, runtime} = DshBeam.Runtime.start_link([], [])

    broken = """
    defmodule SbxBroken do
      def mount(_config), do: :wrong_shape
    end
    """

    assert {:error, {:mount, _errors}} = DshBeam.Sandbox.define(runtime, broken)
    assert DshBeam.Runtime.entries(runtime) == %{}
    assert Code.ensure_loaded?(SbxBroken) == false
  end

  test "atoms created by untrusted source stay in the child" do
    {:ok, runtime} = DshBeam.Runtime.start_link([], [])
    ctx = DshBeam.Runtime.context(runtime)

    suffix = "bomb_#{System.unique_integer([:positive])}"

    source = """
    defmodule SbxAtomMaker do
      def mount(_config) do
        # would poison the host atom table if this ran in-process
        _atom = String.to_atom("sbx_#{suffix}")
        {:ok, [], %{"ok" => true}, %{}}
      end
    end
    """

    assert {:ok, _entry} = DshBeam.Sandbox.define(runtime, source)
    assert DshBeam.Context.get(ctx, :ok) == {:ok, true}

    # the atom made by untrusted code exists only in the child's atom table:
    # on this OTP, to_existing_atom raises when the atom is absent
    assert_raise ArgumentError, fn -> String.to_existing_atom("sbx_#{suffix}") end
  end

  defp tmp_path do
    Path.join(System.tmp_dir!(), "dsh_sbx_#{System.unique_integer([:positive])}.txt")
  end

  defp wait_until(fun), do: wait_until(fun, 600)

  defp wait_until(fun, tries) when is_function(fun, 0) do
    cond do
      fun.() ->
        :ok

      tries <= 0 ->
        raise "condition not reached"

      true ->
        Process.sleep(10)
        wait_until(fun, tries - 1)
    end
  end
end

defmodule SbxSlowConsumer do
  @moduledoc false
  use DshBeam.Plugin

  @impl DshBeam.Plugin
  def mount(_ctx, opts) do
    extra = %{parent: Keyword.get(opts, :parent), drain_ms: Keyword.fetch!(opts, :drain_ms)}
    {:ok, Keyword.fetch!(opts, :deps), %{}, extra}
  end

  @impl DshBeam.Plugin
  def handle_dsh_ready(state) do
    if state.extra.parent,
      do: send(state.extra.parent, {:slow_registered, self(), state.fiber_state})

    {:ok, state}
  end

  @impl DshBeam.Plugin
  def handle_dsh_withdraw(keys, state) do
    # slow teardown: keeps the provider's binding in withdrawal long enough
    # for an immediate re-injection to race it
    Process.sleep(state.extra.drain_ms)

    if state.extra.parent, do: send(state.extra.parent, {:slow_drained, self(), keys})
    {:ok, state}
  end
end
