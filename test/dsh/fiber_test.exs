defmodule SlowWithdrawConsumer do
  @moduledoc false
  use Dsh.Plugin

  @impl Dsh.Plugin
  def mount(_ctx, opts) do
    {:ok, [:session], %{}, %{parent: Keyword.fetch!(opts, :parent)}}
  end

  @impl Dsh.Plugin
  def handle_dsh_withdraw(_keys, state) do
    # runs inside the fiber's :unloading state: the fiber knows it is leaving
    send(state.extra.parent, {:slow_withdraw_started, self(), state.fiber_state})
    Process.sleep(200)
    send(state.extra.parent, {:slow_withdraw_finished, self()})
    {:ok, state}
  end
end

defmodule CrashOnDemand do
  @moduledoc false
  use GenServer

  def start_link(ctx, opts) do
    GenServer.start_link(__MODULE__, {ctx, opts})
  end

  def crash(pid), do: send(pid, :crash)

  @impl true
  def init({ctx, _opts}) do
    {:ok, _state, _view} =
      Dsh.Context.register(ctx, id: :boom, deps: [], provides: %{boom: :value})

    {:ok, %{ctx: ctx}}
  end

  @impl true
  def handle_info(:crash, _state) do
    # an abnormal crash after registration: no terminate, the context's
    # monitor safety net must recover the bindings
    raise "crash after registration"
  end
end

defmodule Dsh.FiberTest do
  use ExUnit.Case, async: true

  test "fiber lifecycle states are observable through the context mirror" do
    {:ok, ctx} = Dsh.Context.start_link([])

    {:ok, consumer} = Dsh.Consumer.start_link(ctx, id: :f1, deps: [:session], parent: self())
    assert_receive {:consumer_registered, :f1, ^consumer, :inactive, %{}}, 1000
    assert Dsh.Plugin.fiber_state(consumer) == :inactive
    assert Dsh.Context.fiber_state(ctx, consumer) == :inactive

    {:ok, provider} = Dsh.Provider.start_link(ctx, id: :p1, provides: %{session: :live})

    assert_receive {:consumer_activated, :f1, ^consumer, [:session]}, 1000
    wait_until(fn -> Dsh.Plugin.fiber_state(consumer) == :active end)
    wait_until(fn -> Dsh.Context.fiber_state(ctx, consumer) == :active end)

    :ok = Dsh.Context.unload(ctx, provider)
    wait_until(fn -> Dsh.Plugin.fiber_state(consumer) == :inactive end)
    wait_until(fn -> Dsh.Context.fiber_state(ctx, consumer) == :inactive end)
  end

  test "the guard holds while a dependent is mid-teardown (:unloading)" do
    {:ok, ctx} = Dsh.Context.start_link([])
    {:ok, provider} = Dsh.Provider.start_link(ctx, id: :p1, provides: %{session: :live})
    {:ok, slow} = SlowWithdrawConsumer.start_link(ctx, id: :slow, parent: self())

    :ok = Dsh.Context.unload(ctx, provider)

    assert_receive {:slow_withdraw_started, ^slow, :unloading}, 1000

    # mid-teardown: the provider has not withdrawn yet (the guard holds)
    assert Dsh.Context.get(ctx, :session) == {:ok, :live}

    assert_receive {:slow_withdraw_finished, ^slow}, 1000
    wait_until(fn -> Dsh.Context.get(ctx, :session) == :not_found end)
    assert Dsh.Plugin.fiber_state(slow) == :inactive
  end

  test "a fiber crashing after registration is isolated; its bindings are recovered" do
    {:ok, ctx} = Dsh.Context.start_link([])
    {:ok, _sibling} = Dsh.Provider.start_link(ctx, id: :sibling, provides: %{other: :ok})
    {:ok, fiber} = CrashOnDemand.start_link(ctx, [])

    # registration completed: the binding is visible
    wait_until(fn -> Dsh.Context.get(ctx, :boom) == {:ok, :value} end)

    # the fiber is linked to us like a supervised child is to its supervisor;
    # unlink so its crash does not take the observer down with it
    Process.unlink(fiber)
    CrashOnDemand.crash(fiber)

    wait_until(fn -> Dsh.Context.get(ctx, :boom) == :not_found end)

    assert Dsh.Context.get(ctx, :boom) == :not_found
    assert Dsh.Context.get(ctx, :other) == {:ok, :ok}
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
