defmodule DshBeam.InterceptTest do
  use ExUnit.Case, async: false

  defp provider_entry(value) do
    %{id: :alpha, plugin: DshBeam.Provider, config: [provides: %{alpha: value}], disabled: false}
  end

  defp intercept_consumer_entry do
    %{id: :intercepted, plugin: InterceptConsumer, config: [], disabled: false}
  end

  defp plain_consumer_entry do
    %{
      id: :plain,
      plugin: DshBeam.Consumer,
      config: [deps: [:alpha], parent: self()],
      disabled: false
    }
  end

  test "an intercepted dependency resolves to a wrapped view, per consumer" do
    {:ok, runtime} =
      DshBeam.Runtime.start_link(
        [provider_entry(42), intercept_consumer_entry(), plain_consumer_entry()],
        []
      )

    assert_receive {:consumer_registered, :plain, plain, :active, %{alpha: 42}}, 2000

    %{intercepted: %{pid: intercepted}} = DshBeam.Runtime.entries(runtime)
    wait_until(fn -> DshBeam.Plugin.fiber_state(intercepted) == :active end)

    # the same provider, two views: one raw, one wrapped
    assert DshBeam.Consumer.view(plain) == %{alpha: 42}
    assert InterceptConsumer.view(intercepted) == %{alpha: %{value: 42, tag: :ro}}
  end

  test "a provider swap re-applies the intercept to the new provider" do
    {:ok, runtime} =
      DshBeam.Runtime.start_link(
        [provider_entry(42), intercept_consumer_entry(), plain_consumer_entry()],
        []
      )

    assert_receive {:consumer_registered, :plain, _plain, :active, _}, 2000
    %{intercepted: %{pid: intercepted}} = DshBeam.Runtime.entries(runtime)
    wait_until(fn -> DshBeam.Plugin.fiber_state(intercepted) == :active end)

    :ok =
      DshBeam.Runtime.reconcile(runtime, [
        provider_entry(99),
        intercept_consumer_entry(),
        plain_consumer_entry()
      ])

    assert_receive {:consumer_activated, :plain, _plain, [:alpha]}, 2000

    wait_until(fn ->
      match?(%{alpha: %{value: 99, tag: :ro}}, InterceptConsumer.view(intercepted))
    end)
  end

  test "removing the provider deactivates the intercepted consumer first (the guard)" do
    {:ok, runtime} =
      DshBeam.Runtime.start_link([provider_entry(42), intercept_consumer_entry()], [])

    ctx = DshBeam.Runtime.context(runtime)
    %{intercepted: %{pid: intercepted}} = DshBeam.Runtime.entries(runtime)
    wait_until(fn -> DshBeam.Plugin.fiber_state(intercepted) == :active end)

    :ok = DshBeam.Runtime.reconcile(runtime, [intercept_consumer_entry()])

    history = DshBeam.Context.history(ctx)

    deactivated =
      Enum.find_index(history, &match?({:deactivated, pid} when pid == intercepted, &1))

    unloaded = Enum.find_index(history, &match?({:unloaded, _pid}, &1))
    assert deactivated != nil and unloaded != nil and deactivated < unloaded

    assert DshBeam.Plugin.fiber_state(intercepted) == :inactive
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

defmodule InterceptWrappers do
  @moduledoc false
  def tag(value, tag), do: %{value: value, tag: tag}
end

defmodule InterceptConsumer do
  @moduledoc false
  use DshBeam.Plugin

  need(:alpha, intercept: {InterceptWrappers, :tag, [:ro]})

  def view(pid), do: :gen_statem.call(pid, :view)

  @impl true
  def handle_event({:call, from}, :view, _state, data) do
    {:keep_state_and_data, [{:reply, from, data.view}]}
  end
end
