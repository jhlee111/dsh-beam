defmodule DslConsumer do
  @moduledoc false
  use DshBeam.Plugin

  need(:session)
end

defmodule DslProvider do
  @moduledoc false
  use DshBeam.Plugin

  provide(:session, value: :live)
end

defmodule DslCalcProvider do
  @moduledoc false
  use DshBeam.Plugin

  provide(:sum, via: {Enum, :sum, [[1, 2, 3]]})
end

defmodule DslComposition do
  @moduledoc false
  use DshBeam.Composition

  entry(:session, DslProvider, config: [])
  entry(:consumer, DslConsumer, config: [])
end

defmodule DshBeam.DslTest do
  use ExUnit.Case, async: true

  test "need/provide declarations compile to the mount contract" do
    {:ok, ctx} = DshBeam.Context.start_link([])

    {:ok, consumer} = DslConsumer.start_link(ctx, id: :c1)
    assert DshBeam.Plugin.fiber_state(consumer) == :inactive

    {:ok, provider} = DslProvider.start_link(ctx, id: :p1)

    wait_until(fn -> DshBeam.Plugin.fiber_state(consumer) == :active end)
    assert DshBeam.Context.get(ctx, :session) == {:ok, :live}

    :ok = DshBeam.Context.unload(ctx, provider)
    wait_until(fn -> DshBeam.Plugin.fiber_state(consumer) == :inactive end)
    assert DshBeam.Context.get(ctx, :session) == :not_found
  end

  test "a via provision computes its value at mount time" do
    {:ok, ctx} = DshBeam.Context.start_link([])

    {:ok, _provider} = DslCalcProvider.start_link(ctx, id: :p2)

    assert DshBeam.Context.get(ctx, :sum) == {:ok, 6}
  end

  test "a composition DSL drives a runtime end to end" do
    entries = DshBeam.Composition.entries(DslComposition)

    assert Enum.map(entries, & &1.id) == [:session, :consumer]
    assert Enum.all?(entries, &(&1.disabled == false))

    {:ok, runtime} = DshBeam.Runtime.start_link(entries, [])
    ctx = DshBeam.Runtime.context(runtime)

    wait_until(fn -> DshBeam.Context.get(ctx, :session) == {:ok, :live} end)

    # reconciliation from the same composition is a no-op and stays sound
    :ok = DshBeam.Runtime.reconcile(runtime, entries)
    assert DshBeam.Context.get(ctx, :session) == {:ok, :live}
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
