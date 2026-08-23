defmodule DshBeam.DistTest do
  use ExUnit.Case, async: false

  # Requires distributed Erlang: EPMD running (`epmd -daemon`) and a magic
  # cookie (~/.erlang.cookie). Without them the tests skip.
  @moduletag :distributed

  setup context do
    cond do
      Node.alive?() ->
        setup_peer(context)

      match?({:ok, _}, Node.start(:dsh_test_master, :shortnames)) ->
        setup_peer(context)

      true ->
        # ExUnit skips a test whose context carries a :skip key; a setup
        # callback may not return {:skip, ...} (that shape is rejected).
        Map.put(context, :skip, "distributed Erlang unavailable (needs epmd + ~/.erlang.cookie)")
    end
  end

  defp setup_peer(context) do
    code_args = Enum.flat_map(:code.get_path(), fn path -> [~c"-pa", path] end)

    case :peer.start_link(%{name: :dsh_test_worker, timeout: 30_000, args: code_args}) do
      {:ok, peer, peer_node} ->
        # keep the peer alive past the test process death, so on_exit can stop it
        Process.unlink(peer)
        on_exit(fn -> :peer.stop(peer) end)
        Map.put(context, :peer_node, peer_node)

      {:error, reason} ->
        Map.put(context, :skip, "peer node unavailable: #{inspect(reason)}")
    end
  end

  defp consumer_entry do
    %{
      id: :consumer,
      plugin: DshBeam.Consumer,
      config: [deps: [:remote_value], parent: self()],
      disabled: false
    }
  end

  test "a remote fiber provides a value a local consumer resolves", %{peer_node: peer_node} do
    {:ok, runtime} = DshBeam.Runtime.start_link([], [])
    ctx = DshBeam.Runtime.context(runtime)

    remote = :rpc.call(peer_node, DshBeam.Dist, :start_provider, [ctx, %{remote_value: 42}])
    assert is_pid(remote)
    assert node(remote) == peer_node

    :ok = DshBeam.Runtime.reconcile(runtime, [consumer_entry()])
    assert_receive {:consumer_registered, :consumer, consumer, :active, %{remote_value: 42}}, 2000

    assert DshBeam.Consumer.view(consumer) == %{remote_value: 42}
  end

  test "unloading the remote provider deactivates the local consumer first (the guard)",
       %{peer_node: peer_node} do
    {:ok, runtime} = DshBeam.Runtime.start_link([], [])
    ctx = DshBeam.Runtime.context(runtime)

    remote = :rpc.call(peer_node, DshBeam.Dist, :start_provider, [ctx, %{remote_value: 42}])
    :ok = DshBeam.Runtime.reconcile(runtime, [consumer_entry()])
    assert_receive {:consumer_registered, :consumer, consumer, :active, _}, 2000

    :ok = DshBeam.Context.unload(ctx, remote)

    history = DshBeam.Context.history(ctx)
    deactivated = Enum.find_index(history, &match?({:deactivated, pid} when pid == consumer, &1))
    unloaded = Enum.find_index(history, &match?({:unloaded, _pid}, &1))
    assert deactivated != nil and unloaded != nil and deactivated < unloaded

    assert DshBeam.Context.get(ctx, :remote_value) == :not_found
    assert DshBeam.Plugin.fiber_state(consumer) == :inactive
  end

  test "a remote fiber crash withdraws through the monitor safety net", %{peer_node: peer_node} do
    {:ok, runtime} = DshBeam.Runtime.start_link([], [])
    ctx = DshBeam.Runtime.context(runtime)

    remote = :rpc.call(peer_node, DshBeam.Dist, :start_provider, [ctx, %{remote_value: 42}])
    :ok = DshBeam.Runtime.reconcile(runtime, [consumer_entry()])
    assert_receive {:consumer_registered, :consumer, consumer, :active, _}, 2000

    # the remote fiber dies; the local monitor safety net withdraws its binding
    Process.exit(remote, :kill)

    wait_until(fn -> DshBeam.Context.get(ctx, :remote_value) == :not_found end)
    assert DshBeam.Plugin.fiber_state(consumer) == :inactive
  end

  defp wait_until(fun), do: wait_until(fun, 400)

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
