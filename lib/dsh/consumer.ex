defmodule Dsh.Consumer do
  @moduledoc """
  A generic plugin that declares dependencies and records its lifecycle — the
  minimal shape of every capability consumer.

  Deactivation keeps the process alive (:inactive) with its committed view
  retained, so the L-Unload guarantee is observable: the binding it held at
  teardown stays recorded after the fact.
  """

  use Dsh.Plugin

  def view(pid), do: :gen_statem.call(pid, :view)
  def state(pid), do: :gen_statem.call(pid, :state)
  def deactivations(pid), do: :gen_statem.call(pid, :deactivations)

  @impl Dsh.Plugin
  def mount(_ctx, opts) do
    extra = %{parent: Keyword.get(opts, :parent), deactivations: []}
    {:ok, Keyword.fetch!(opts, :deps), %{}, extra}
  end

  @impl Dsh.Plugin
  def handle_dsh_ready(state) do
    notify(
      state.extra.parent,
      {:consumer_registered, state.id, self(), state.fiber_state, state.view}
    )

    {:ok, state}
  end

  @impl Dsh.Plugin
  def handle_dsh_withdraw(keys, state) do
    notify(state.extra.parent, {:consumer_deactivated, state.id, self(), keys, state.view})

    extra = %{state.extra | deactivations: [{keys, state.view} | state.extra.deactivations]}
    {:ok, %{state | extra: extra}}
  end

  @impl Dsh.Plugin
  def handle_dsh_activate(view, state) do
    notify(state.extra.parent, {:consumer_activated, state.id, self(), Map.keys(view)})
    {:ok, state}
  end

  @impl true
  def handle_event({:call, from}, :view, _state, data) do
    {:keep_state_and_data, [{:reply, from, data.view}]}
  end

  def handle_event({:call, from}, :state, _state, data) do
    {:keep_state_and_data, [{:reply, from, data.fiber_state}]}
  end

  def handle_event({:call, from}, :deactivations, _state, data) do
    {:keep_state_and_data, [{:reply, from, data.extra.deactivations}]}
  end

  defp notify(nil, _msg), do: :ok
  defp notify(parent, msg) when is_pid(parent), do: send(parent, msg)
end
