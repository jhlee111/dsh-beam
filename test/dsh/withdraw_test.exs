defmodule StubbornDependent do
  @moduledoc false
  use GenServer

  def start_link(ctx, opts) do
    GenServer.start_link(__MODULE__, {ctx, opts})
  end

  @impl true
  def init({ctx, _opts}) do
    {:ok, _state, _view} =
      DshBeam.Context.register(ctx, id: :stubborn, deps: [:session], provides: %{})

    {:ok, %{ctx: ctx}}
  end

  @impl true
  def handle_info({:dsh_withdraw, _keys}, st) do
    # declares deps but never acknowledges withdrawal — the context must fall
    # back on its deactivation timeout instead of waiting forever or crashing.
    {:noreply, st}
  end
end

defmodule ReentrantDependent do
  @moduledoc false
  use GenServer

  def start_link(ctx, opts) do
    GenServer.start_link(__MODULE__, {ctx, opts})
  end

  def result(pid), do: GenServer.call(pid, :result)

  @impl true
  def init({ctx, opts}) do
    {:ok, _state, _view} =
      DshBeam.Context.register(ctx, id: :reentrant, deps: [:session], provides: %{})

    {:ok, %{ctx: ctx, parent: Keyword.fetch!(opts, :parent), result: nil}}
  end

  @impl true
  def handle_info({:dsh_withdraw, _keys}, st) do
    # calls back into the context during its own teardown — the context must
    # be free to answer (no reentrancy cycle).
    result = DshBeam.Context.get(st.ctx, :session)
    send(st.parent, {:reentrant_teardown_read, result})
    {:noreply, %{st | result: result}}
  end

  @impl true
  def handle_call(:result, _from, st), do: {:reply, st.result, st}
end

defmodule DshBeam.WithdrawTest do
  use ExUnit.Case, async: true

  test "a dependent that never acknowledges cannot stall the context (B-H1 regression)" do
    {:ok, ctx} = DshBeam.Context.start_link(deactivate_timeout: 100)
    {:ok, provider} = DshBeam.Provider.start_link(ctx, id: :p1, provides: %{session: :live})
    {:ok, stubborn} = StubbornDependent.start_link(ctx, [])

    wait_until(fn -> DshBeam.Context.fiber_state(ctx, stubborn) == :active end)

    :ok = DshBeam.Context.unload(ctx, provider)

    wait_until(fn -> DshBeam.Context.get(ctx, :session) == :not_found end)
    assert DshBeam.Context.get(ctx, :session) == :not_found

    history = DshBeam.Context.history(ctx)
    assert Enum.any?(history, &match?({:unload_forced, pid} when pid == provider, &1))
  end

  test "a dependent may call the context during its own teardown (B-H2 regression)" do
    {:ok, ctx} = DshBeam.Context.start_link([])
    {:ok, provider} = DshBeam.Provider.start_link(ctx, id: :p1, provides: %{session: :live})
    {:ok, dependent} = ReentrantDependent.start_link(ctx, parent: self())

    wait_until(fn -> DshBeam.Context.fiber_state(ctx, dependent) == :active end)

    :ok = DshBeam.Context.unload(ctx, provider)

    assert_receive {:reentrant_teardown_read, {:ok, :live}}, 1000
    wait_until(fn -> DshBeam.Context.get(ctx, :session) == :not_found end)
    assert ReentrantDependent.result(dependent) == {:ok, :live}
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
end
