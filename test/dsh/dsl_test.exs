defmodule DslConsumer do
  @moduledoc false
  use Dsh.Plugin

  need(:session)
end

defmodule DslProvider do
  @moduledoc false
  use Dsh.Plugin

  provide(:session, value: :live)
end

defmodule DslCalcProvider do
  @moduledoc false
  use Dsh.Plugin

  provide(:sum, via: {Enum, :sum, [[1, 2, 3]]})
end

defmodule DslComposition do
  @moduledoc false
  use Dsh.Composition

  entry(:session, DslProvider, config: [])
  entry(:consumer, DslConsumer, config: [])
end

defmodule Dsh.DslTest do
  use ExUnit.Case, async: true

  test "need/provide declarations compile to the mount contract" do
    {:ok, ctx} = Dsh.Context.start_link([])

    {:ok, consumer} = DslConsumer.start_link(ctx, id: :c1)
    assert Dsh.Plugin.fiber_state(consumer) == :inactive

    {:ok, provider} = DslProvider.start_link(ctx, id: :p1)

    wait_until(fn -> Dsh.Plugin.fiber_state(consumer) == :active end)
    assert Dsh.Context.get(ctx, :session) == {:ok, :live}

    :ok = Dsh.Context.unload(ctx, provider)
    wait_until(fn -> Dsh.Plugin.fiber_state(consumer) == :inactive end)
    assert Dsh.Context.get(ctx, :session) == :not_found
  end

  test "a via provision computes its value at mount time" do
    {:ok, ctx} = Dsh.Context.start_link([])

    {:ok, _provider} = DslCalcProvider.start_link(ctx, id: :p2)

    assert Dsh.Context.get(ctx, :sum) == {:ok, 6}
  end

  test "a composition DSL drives a runtime end to end" do
    entries = Dsh.Composition.entries(DslComposition)

    assert Enum.map(entries, & &1.id) == [:session, :consumer]
    assert Enum.all?(entries, &(&1.disabled == false))

    {:ok, runtime} = Dsh.Runtime.start_link(entries, [])
    ctx = Dsh.Runtime.context(runtime)

    wait_until(fn -> Dsh.Context.get(ctx, :session) == {:ok, :live} end)

    # reconciliation from the same composition is a no-op and stays sound
    :ok = Dsh.Runtime.reconcile(runtime, entries)
    assert Dsh.Context.get(ctx, :session) == {:ok, :live}
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
