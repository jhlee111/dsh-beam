defmodule Dsh.ContextTest do
  use ExUnit.Case, async: true

  setup do
    {:ok, ctx} = Dsh.Context.start_link([])
    %{ctx: ctx}
  end

  test "unload recovers exactly the owner's provisions; others stay", %{ctx: ctx} do
    :ok = Dsh.Context.provide(ctx, :a, :va)
    :ok = Dsh.Context.provide(ctx, :b, :vb)

    {:ok, _other} = Dsh.Provider.start_link(ctx, id: :other, provides: %{c: :vc})

    :ok = Dsh.Context.unload(ctx, self())

    assert Dsh.Context.get(ctx, :a) == :not_found
    assert Dsh.Context.get(ctx, :b) == :not_found
    assert Dsh.Context.get(ctx, :c) == {:ok, :vc}

    assert {:error, :already_provided} = Dsh.Context.provide(ctx, :c, :sneaky)
  end

  test "provide then register merges into one fiber; unload recovers both (H3 regression)", %{
    ctx: ctx
  } do
    :ok = Dsh.Context.provide(ctx, :a, :va)

    {:ok, _state, _view} = Dsh.Context.register(ctx, id: :merged, deps: [], provides: %{b: :vb})

    :ok = Dsh.Context.unload(ctx, self())

    assert Dsh.Context.get(ctx, :a) == :not_found
    assert Dsh.Context.get(ctx, :b) == :not_found
  end

  test "reactive coeffects: a dependent activates when its key appears", %{ctx: ctx} do
    {:ok, consumer} = Dsh.Consumer.start_link(ctx, id: :c1, deps: [:session], parent: self())
    assert_receive {:consumer_registered, :c1, ^consumer, :inactive, %{}}, 1000

    {:ok, _provider} = Dsh.Provider.start_link(ctx, id: :p1, provides: %{session: :live})

    assert_receive {:consumer_activated, :c1, ^consumer, [:session]}, 1000
    assert Dsh.Consumer.state(consumer) == :active
    assert Dsh.Consumer.view(consumer) == %{session: :live}
  end

  test "L-Unload guard: the dependent deactivates before the provider withdraws", %{ctx: ctx} do
    {:ok, provider} = Dsh.Provider.start_link(ctx, id: :p1, provides: %{session: :live})
    {:ok, consumer} = Dsh.Consumer.start_link(ctx, id: :c1, deps: [:session], parent: self())
    assert_receive {:consumer_registered, :c1, ^consumer, :active, %{session: :live}}, 1000

    :ok = Dsh.Context.unload(ctx, provider)

    assert_receive {:consumer_deactivated, :c1, ^consumer, [:session], %{session: :live}}, 1000
    wait_until(fn -> Dsh.Context.get(ctx, :session) == :not_found end)

    history = Dsh.Context.history(ctx)
    deactivated = Enum.find_index(history, &match?({:deactivated, pid} when pid == consumer, &1))
    unloaded = Enum.find_index(history, &match?({:unloaded, pid} when pid == provider, &1))

    assert deactivated != nil
    assert unloaded != nil
    assert deactivated < unloaded

    # the fiber survives deactivation, with its committed view retained
    assert Dsh.Consumer.state(consumer) == :inactive
    assert [{[:session], %{session: :live}}] = Dsh.Consumer.deactivations(consumer)
  end

  test "owner death withdraws its bindings (the OTP safety net)", %{ctx: ctx} do
    {:ok, provider} = Dsh.Provider.start_link(ctx, id: :p1, provides: %{session: :live})
    wait_until(fn -> Dsh.Context.get(ctx, :session) == {:ok, :live} end)

    # In the real runtime the plugin links to its supervisor (which traps
    # exits), not to the observer. Unlink mirrors that topology before killing.
    Process.unlink(provider)
    Process.exit(provider, :kill)
    wait_until(fn -> Dsh.Context.get(ctx, :session) == :not_found end)

    assert Dsh.Context.get(ctx, :session) == :not_found
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
