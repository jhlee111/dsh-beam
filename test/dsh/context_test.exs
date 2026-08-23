defmodule DshBeam.ContextTest do
  use ExUnit.Case, async: true

  setup do
    {:ok, ctx} = DshBeam.Context.start_link([])
    %{ctx: ctx}
  end

  test "unload recovers exactly the owner's provisions; others stay", %{ctx: ctx} do
    :ok = DshBeam.Context.provide(ctx, :a, :va)
    :ok = DshBeam.Context.provide(ctx, :b, :vb)

    {:ok, _other} = DshBeam.Provider.start_link(ctx, id: :other, provides: %{c: :vc})

    :ok = DshBeam.Context.unload(ctx, self())

    assert DshBeam.Context.get(ctx, :a) == :not_found
    assert DshBeam.Context.get(ctx, :b) == :not_found
    assert DshBeam.Context.get(ctx, :c) == {:ok, :vc}

    assert {:error, :already_provided} = DshBeam.Context.provide(ctx, :c, :sneaky)
  end

  test "provide then register merges into one fiber; unload recovers both (H3 regression)", %{
    ctx: ctx
  } do
    :ok = DshBeam.Context.provide(ctx, :a, :va)

    {:ok, _state, _view} =
      DshBeam.Context.register(ctx, id: :merged, deps: [], provides: %{b: :vb})

    :ok = DshBeam.Context.unload(ctx, self())

    assert DshBeam.Context.get(ctx, :a) == :not_found
    assert DshBeam.Context.get(ctx, :b) == :not_found
  end

  test "reactive coeffects: a dependent activates when its key appears", %{ctx: ctx} do
    {:ok, consumer} = DshBeam.Consumer.start_link(ctx, id: :c1, deps: [:session], parent: self())
    assert_receive {:consumer_registered, :c1, ^consumer, :inactive, %{}}, 1000

    {:ok, _provider} = DshBeam.Provider.start_link(ctx, id: :p1, provides: %{session: :live})

    assert_receive {:consumer_activated, :c1, ^consumer, [:session]}, 1000
    assert DshBeam.Consumer.state(consumer) == :active
    assert DshBeam.Consumer.view(consumer) == %{session: :live}
  end

  test "L-Unload guard: the dependent deactivates before the provider withdraws", %{ctx: ctx} do
    {:ok, provider} = DshBeam.Provider.start_link(ctx, id: :p1, provides: %{session: :live})
    {:ok, consumer} = DshBeam.Consumer.start_link(ctx, id: :c1, deps: [:session], parent: self())
    assert_receive {:consumer_registered, :c1, ^consumer, :active, %{session: :live}}, 1000

    :ok = DshBeam.Context.unload(ctx, provider)

    assert_receive {:consumer_deactivated, :c1, ^consumer, [:session], %{session: :live}}, 1000
    wait_until(fn -> DshBeam.Context.get(ctx, :session) == :not_found end)

    history = DshBeam.Context.history(ctx)
    deactivated = Enum.find_index(history, &match?({:deactivated, pid} when pid == consumer, &1))
    unloaded = Enum.find_index(history, &match?({:unloaded, pid} when pid == provider, &1))

    assert deactivated != nil
    assert unloaded != nil
    assert deactivated < unloaded

    # the fiber survives deactivation, with its committed view retained
    assert DshBeam.Consumer.state(consumer) == :inactive
    assert [{[:session], %{session: :live}}] = DshBeam.Consumer.deactivations(consumer)
  end

  test "owner death withdraws its bindings (the OTP safety net)", %{ctx: ctx} do
    {:ok, provider} = DshBeam.Provider.start_link(ctx, id: :p1, provides: %{session: :live})
    wait_until(fn -> DshBeam.Context.get(ctx, :session) == {:ok, :live} end)

    # In the real runtime the plugin links to its supervisor (which traps
    # exits), not to the observer. Unlink mirrors that topology before killing.
    Process.unlink(provider)
    Process.exit(provider, :kill)
    wait_until(fn -> DshBeam.Context.get(ctx, :session) == :not_found end)

    assert DshBeam.Context.get(ctx, :session) == :not_found
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
