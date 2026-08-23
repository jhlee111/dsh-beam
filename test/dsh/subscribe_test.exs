defmodule DshBeam.SubscribeTest do
  use ExUnit.Case, async: false

  test "a context subscriber receives the event stream in order" do
    {:ok, ctx} = DshBeam.Context.start_link([])
    :ok = DshBeam.Context.subscribe(ctx)

    {:ok, provider} = DshBeam.Provider.start_link(ctx, id: :provider, provides: %{k: 1})

    assert_receive {:dsh_event, {:registered, ^provider, :provider}}, 1000
    assert_receive {:dsh_event, {:fiber_state, ^provider, :active}}, 1000

    :ok = DshBeam.Context.unload(ctx, provider)

    assert_receive {:dsh_event, {:unloading, ^provider}}, 1000
    assert_receive {:dsh_event, {:unloaded, ^provider}}, 1000
    assert DshBeam.Context.get(ctx, :k) == :not_found
  end

  test "a dead context subscriber is cleaned up" do
    {:ok, ctx} = DshBeam.Context.start_link([])
    parent = self()

    subscriber =
      spawn(fn ->
        :ok = DshBeam.Context.subscribe(ctx)
        send(parent, :subscribed)
        Process.sleep(:infinity)
      end)

    assert_receive :subscribed, 1000
    :ok = DshBeam.Context.subscribe(ctx)
    Process.exit(subscriber, :kill)

    wait_until(fn -> map_size(:sys.get_state(ctx).subscribers) == 1 end)

    # the context still works and only the live subscriber is fanned out to
    {:ok, _provider} = DshBeam.Provider.start_link(ctx, id: :provider, provides: %{k: 1})
    assert_receive {:dsh_event, {:registered, _pid, :provider}}, 1000
  end

  test "a runtime subscriber receives entry changes" do
    {:ok, runtime} = DshBeam.Runtime.start_link([], [])
    :ok = DshBeam.Runtime.subscribe(runtime)

    entry = %{id: :k, plugin: DshBeam.Provider, config: [provides: %{k: 1}], disabled: false}
    :ok = DshBeam.Runtime.reconcile(runtime, [entry])

    assert_receive {:dsh_runtime_event, {:k, rec}}, 1000
    assert is_pid(rec.pid) and rec.error == nil

    :ok = DshBeam.Runtime.reconcile(runtime, [])
    assert_receive {:dsh_runtime_event, {:k, :removed}}, 1000
  end

  test "a runtime subscriber sees crash and re-injection events" do
    {:ok, runtime} = DshBeam.Runtime.start_link([], [])
    :ok = DshBeam.Runtime.subscribe(runtime)

    entry = %{id: :x, plugin: SubscribeCrashLoop, config: [], disabled: false}
    :ok = DshBeam.Runtime.reconcile(runtime, [entry])

    # the restart cycle ends in the terminal state, all announced
    wait_for_event(fn event ->
      match?({:dsh_runtime_event, {:x, %{error: :crash_loop}}}, event)
    end)
  end

  defp wait_until(fun), do: wait_until(fun, 200)

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

  defp wait_for_event(match?) do
    deadline = System.monotonic_time(:millisecond) + 4000
    do_wait_for_event(match?, deadline)
  end

  defp do_wait_for_event(match?, deadline) do
    timeout = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      event ->
        if match?.(event), do: :ok, else: do_wait_for_event(match?, deadline)
    after
      timeout ->
        raise "event not received"
    end
  end
end

defmodule SubscribeCrashLoop do
  @moduledoc false
  use GenServer

  def start_link(ctx, opts) do
    GenServer.start_link(__MODULE__, {ctx, opts})
  end

  @impl true
  def init(_args), do: {:ok, %{}, {:continue, :crash}}

  @impl true
  def handle_continue(:crash, _state), do: raise("boom")
end
