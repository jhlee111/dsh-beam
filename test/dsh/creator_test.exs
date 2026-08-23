defmodule Dsh.CreatorTest do
  use ExUnit.Case, async: false

  @provider_v1 """
  defmodule MadeValueProvider do
    use Dsh.Plugin
    provide :made_value, value: 42
  end
  """

  @provider_v2 """
  defmodule MadeValueProvider do
    use Dsh.Plugin
    provide :made_value, value: 99
  end
  """

  @consumer """
  defmodule MadeValueConsumer do
    use Dsh.Plugin
    need :made_value

    @impl Dsh.Plugin
    def handle_dsh_ready(state), do: notify(state)

    @impl Dsh.Plugin
    def handle_dsh_activate(_view, state), do: notify(state)

    defp notify(state) do
      if parent = state.config[:parent], do: send(parent, {:made_view, self(), state.view})
      {:ok, state}
    end
  end
  """

  test "define, hot-redefine, and undefine a creator-written plugin" do
    {:ok, runtime} = Dsh.Runtime.start_link([], [])
    ctx = Dsh.Runtime.context(runtime)

    # define: compile -> load -> mount
    assert {:ok, MadeValueProvider} = Dsh.Creator.define(runtime, @provider_v1)
    assert Dsh.Context.get(ctx, :made_value) == {:ok, 42}

    # a dependent written by the creator activates against it
    assert {:ok, MadeValueConsumer} =
             Dsh.Creator.define(runtime, @consumer, config: [parent: self()])

    assert_receive {:made_view, consumer, %{made_value: 42}}, 2000
    assert Dsh.Plugin.fiber_state(consumer) == :active

    # hot-redefine: the old fiber withdraws (guard), the new one binds
    assert {:ok, MadeValueProvider} = Dsh.Creator.redefine(runtime, @provider_v2)

    assert_receive {:made_view, ^consumer, %{made_value: 99}}, 2000
    wait_until(fn -> Dsh.Context.get(ctx, :made_value) == {:ok, 99} end)

    # undefine: clean withdrawal, dependent deactivates
    :ok = Dsh.Creator.undefine(runtime, MadeValueProvider)
    wait_until(fn -> Dsh.Context.get(ctx, :made_value) == :not_found end)
    wait_until(fn -> Dsh.Plugin.fiber_state(consumer) == :inactive end)
  end

  test "a creator-written plugin that crashes at mount is isolated" do
    {:ok, runtime} = Dsh.Runtime.start_link([], [])
    ctx = Dsh.Runtime.context(runtime)

    faulty = """
    defmodule MadeFaulty do
      use Dsh.Plugin
      provide :faulty, value: :x

      @impl Dsh.Plugin
      def handle_dsh_ready(_state), do: raise("boom")
    end
    """

    assert {:error, {:mount, _reason}} = Dsh.Creator.define(runtime, faulty)

    # the partial registration was recovered by the monitor safety net
    wait_until(fn -> Dsh.Context.get(ctx, :faulty) == :not_found end)
    assert Dsh.Context.get(ctx, :faulty) == :not_found

    # the context stays responsive for the next definition
    assert {:ok, MadeValueProvider} = Dsh.Creator.define(runtime, @provider_v1)
    assert Dsh.Context.get(ctx, :made_value) == {:ok, 42}
  end

  test "a syntax error is loud and mounts nothing" do
    {:ok, runtime} = Dsh.Runtime.start_link([], [])

    broken = "defmodule MadeSyntax do use Dsh.Plugin; need"
    assert {:error, {:compile, _result}} = Dsh.Creator.define(runtime, broken)

    assert Dsh.Runtime.entries(runtime) == %{}
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
