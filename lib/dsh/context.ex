defmodule DshBeam.Context do
  @moduledoc """
  The unified context: one GenServer state carrying the coeffect store
  (key -> provided value) and the fiber registry, realizing revertible effects
  and reactive coeffects over it (paper §3.3).

  ## Revertible effects (temporal composability, §3.1)

  provide/3 adds a binding and captures an inverse that removes exactly that
  binding. Inverses accumulate per fiber (LIFO) and the unload path applies
  them in reverse application order, so withdrawing a plugin recovers the
  context to its pre-composition state.

  ## Reactive coeffects (spatial composability, §3.2)

  A fiber declares dependency keys. Resolution yields the committed view; when
  a provision appears or disappears, dependents activate or deactivate
  against it.

  ## L-Unload guard (§4.3.1)

  Withdrawal is ordered: unload/2 marks the provider fiber :unloading and
  sends {:dsh_withdraw, keys} to its active dependents; the binding is
  withdrawn only after every dependent has acknowledged ({:dsh_deactivated,
  pid, keys}), died, or the deactivation timeout elapsed. During their own
  teardown dependents can still read the binding and call this context — the
  context never blocks on a call into a dependent, so no reentrancy cycle is
  possible. The unloader is notified with {:dsh_unloaded, owner} once the
  withdrawal is complete.

  The owner of every registration is the calling process. If an owner dies
  without unloading, a monitor triggers an immediate withdrawal: the coarse
  OTP safety net behind the fine-grained accumulator.
  """

  use GenServer

  alias DshBeam.{Coeffect, Effect, Fiber}

  # -- public API --

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
  end

  def register(ctx, opts), do: GenServer.call(ctx, {:register, opts})

  def provide(ctx, key, value), do: GenServer.call(ctx, {:provide, key, value})

  @doc """
  Register a raw inverse effect for the calling fiber. The closure
  (state -> state) joins the fiber's LIFO accumulator and runs when its
  bindings are withdrawn — after dependents drained, even when the fiber's
  process crashed. This is how a provider ties a resource's release to the
  withdrawal protocol.
  """
  def effect(ctx, inverse) when is_function(inverse, 1) do
    GenServer.call(ctx, {:effect, inverse})
  end

  def get(ctx, key), do: GenServer.call(ctx, {:get, key})

  def resolve(ctx), do: GenServer.call(ctx, :resolve)

  def fiber_state(ctx, owner), do: GenServer.call(ctx, {:fiber_state, owner})

  def unload(ctx, owner), do: GenServer.call(ctx, {:unload, owner})

  def snapshot(ctx), do: GenServer.call(ctx, :snapshot)

  def history(ctx), do: GenServer.call(ctx, :history)

  # -- GenServer --

  @impl true
  def init(opts) do
    state = %{
      bindings: %{},
      owners: %{},
      fibers: %{},
      monitors: %{},
      pending: %{},
      deactivate_timeout: Keyword.get(opts, :deactivate_timeout, 1000),
      history: []
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:register, opts}, {owner, _tag}, state) do
    id = Keyword.fetch!(opts, :id)
    deps = MapSet.new(Keyword.get(opts, :deps, []))
    provides = Keyword.get(opts, :provides, %{})
    dupes = Enum.filter(Map.keys(provides), &Map.has_key?(state.bindings, &1))

    if dupes != [] do
      {:reply, {:error, {:already_provided, dupes}}, state}
    else
      {state, inverses} =
        Enum.reduce(provides, {state, []}, fn {key, value}, {st, invs} ->
          {st, inverse} = put_binding(st, key, value, owner)
          {st, [inverse | invs]}
        end)

      # Merge into the owner's existing fiber instead of replacing it: the
      # owner may already hold effect inverses from provide/3, and dropping
      # them would break recovery exactness (review finding H3).
      existing =
        case Map.get(state.fibers, owner) do
          nil -> %Fiber{id: id, owner: owner}
          %Fiber{} = fiber -> fiber
        end

      fiber = %Fiber{
        existing
        | id: id,
          deps: deps,
          provides: MapSet.union(existing.provides, MapSet.new(Map.keys(provides))),
          inverses: inverses ++ existing.inverses
      }

      state =
        state
        |> put_fiber(fiber)
        |> put_monitor(owner)
        |> log({:registered, owner, id})

      {state, fiber_state, view} = reactivate(state, fiber)
      {:reply, {:ok, fiber_state, view}, state}
    end
  end

  @impl true
  def handle_call({:provide, key, value}, {owner, _tag}, state) do
    if Map.has_key?(state.bindings, key) do
      {:reply, {:error, :already_provided}, state}
    else
      {state, inverse} = put_binding(state, key, value, owner)

      fiber = Map.get(state.fibers, owner, %Fiber{id: {:anon, owner}, owner: owner})

      fiber = %{
        fiber
        | inverses: [inverse | fiber.inverses],
          provides: MapSet.put(fiber.provides, key)
      }

      state =
        state
        |> put_fiber(fiber)
        |> put_monitor(owner)
        |> log({:provided, owner, key})

      {state, _fiber_state, _view} = reactivate(state, fiber)
      {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:effect, inverse}, {owner, _tag}, state) do
    fiber = Map.get(state.fibers, owner, %Fiber{id: {:anon, owner}, owner: owner})
    fiber = %{fiber | inverses: [inverse | fiber.inverses]}

    state =
      state
      |> put_fiber(fiber)
      |> put_monitor(owner)

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:get, key}, _from, state) do
    case Map.fetch(state.bindings, key) do
      {:ok, value} -> {:reply, {:ok, value}, state}
      :error -> {:reply, :not_found, state}
    end
  end

  @impl true
  def handle_call(:resolve, {owner, _tag}, state) do
    case Map.get(state.fibers, owner) do
      nil ->
        {:reply, :unknown, state}

      fiber ->
        case Coeffect.resolve(state.bindings, fiber.deps) do
          {:satisfied, view} -> {:reply, {:active, view}, state}
          {:unsatisfied, view, _missing} -> {:reply, {:inactive, view}, state}
        end
    end
  end

  @impl true
  def handle_call({:fiber_state, owner}, _from, state) do
    case Map.get(state.fibers, owner) do
      nil -> {:reply, :unknown, state}
      fiber -> {:reply, fiber.state, state}
    end
  end

  @impl true
  def handle_call({:unload, owner}, _from, state) do
    {:reply, :ok, begin_unload(state, owner)}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    fibers =
      Map.new(state.fibers, fn {pid, f} ->
        {pid, %{id: f.id, state: f.state, deps: f.deps, provides: f.provides}}
      end)

    {:reply, %{bindings: state.bindings, fibers: fibers}, state}
  end

  @impl true
  def handle_call(:history, _from, state) do
    {:reply, Enum.reverse(state.history), state}
  end

  @impl true
  def handle_info({:dsh_deactivated, pid, _keys}, state) do
    {:noreply, acknowledge(state, pid)}
  end

  # The fiber reports its own transitions; the context mirror follows it and
  # never leads it.
  def handle_info({:dsh_fiber_state, pid, fiber_state}, state) do
    case Map.get(state.fibers, pid) do
      nil -> {:noreply, state}
      fiber -> {:noreply, put_fiber(state, %{fiber | state: fiber_state})}
    end
  end

  def handle_info({:dsh_unload_timeout, owner}, state) do
    case Map.get(state.pending, owner) do
      nil -> {:noreply, state}
      _pending -> {:noreply, finalize_unload(state, owner, :unload_forced)}
    end
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    state = %{state | monitors: Map.delete(state.monitors, pid)}
    # a dependent that died mid-teardown counts as teardown-complete
    state = acknowledge(state, pid)

    state =
      if Map.has_key?(state.pending, pid) do
        # the unload requester itself died mid-withdrawal: complete now
        finalize_unload(state, pid, :unloaded)
      else
        crash_withdraw(state, pid)
      end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- internals --

  defp put_binding(state, key, value, owner) do
    inverse = fn st -> remove_binding(st, key, owner) end

    state = %{
      state
      | bindings: Map.put(state.bindings, key, value),
        owners: Map.put(state.owners, key, owner)
    }

    {state, inverse}
  end

  defp remove_binding(state, key, owner) do
    case Map.fetch(state.owners, key) do
      {:ok, ^owner} ->
        %{
          state
          | bindings: Map.delete(state.bindings, key),
            owners: Map.delete(state.owners, key)
        }

      _ ->
        state
    end
  end

  defp put_fiber(state, fiber) do
    %{state | fibers: Map.put(state.fibers, fiber.owner, fiber)}
  end

  # Keyed by owner pid so membership checks stay O(1); :DOWN messages carry
  # the pid directly, so no ref lookup is needed.
  defp put_monitor(state, owner) do
    if Map.has_key?(state.monitors, owner) do
      state
    else
      ref = Process.monitor(owner)
      %{state | monitors: Map.put(state.monitors, owner, ref)}
    end
  end

  defp demonitor_owner(state, owner) do
    case Map.pop(state.monitors, owner) do
      {nil, monitors} ->
        %{state | monitors: monitors}

      {ref, monitors} ->
        Process.demonitor(ref, [:flush])
        %{state | monitors: monitors}
    end
  end

  @max_history 200

  defp log(state, event) do
    %{state | history: Enum.take([event | state.history], @max_history)}
  end

  # Bindings of fibers that are mid-withdrawal do not satisfy new resolutions
  # (the paper's L-Leave: a departing provider stops providing), while
  # committed reads still see them.
  defp active_bindings(state) do
    unloading =
      for {pid, fiber} <- state.fibers, fiber.state == :unloading, into: MapSet.new(), do: pid

    withdrawing_keys = for {key, pid} <- state.owners, MapSet.member?(unloading, pid), do: key
    Map.drop(state.bindings, withdrawing_keys)
  end

  defp reactivate(state, subject) do
    {subject_state, own_view} =
      case Coeffect.resolve(active_bindings(state), subject.deps) do
        {:satisfied, view} -> {:active, view}
        {:unsatisfied, view, _missing} -> {:inactive, view}
      end

    state = put_fiber(state, %{subject | state: subject_state})

    state =
      Enum.reduce(subject.provides, state, fn key, st ->
        Enum.reduce(st.fibers, st, fn {pid, fiber}, st2 ->
          cond do
            pid == subject.owner ->
              st2

            fiber.state != :inactive ->
              st2

            not MapSet.member?(fiber.deps, key) ->
              st2

            true ->
              case Coeffect.resolve(active_bindings(st2), fiber.deps) do
                {:satisfied, view} ->
                  send(pid, {:dsh_activate, view})

                  st2
                  |> put_fiber(%{fiber | state: :reloading})
                  |> log({:activated, pid, Map.keys(view)})

                {:unsatisfied, _view, _missing} ->
                  st2
              end
          end
        end)
      end)

    {state, subject_state, own_view}
  end

  defp active_dependents(state, fiber) do
    for {pid, dep} <- state.fibers,
        pid != fiber.owner,
        dep.state in [:active, :reloading],
        not MapSet.disjoint?(dep.deps, fiber.provides),
        into: MapSet.new(),
        do: pid
  end

  defp begin_unload(state, owner) do
    case Map.get(state.fibers, owner) do
      nil -> withdraw_owner_bindings(state, owner)
      fiber -> ordered_withdraw(state, owner, fiber)
    end
  end

  # The single withdrawal path for both the graceful unload and the crash
  # path: dependents drain first, then the accumulator runs (L-Unload). A
  # crashed provider's resource-release inverses therefore still run after
  # its dependents finished their teardown — ordered shutdown.
  defp ordered_withdraw(state, owner, fiber) do
    dependents = active_dependents(state, fiber)
    state = log(state, {:unloading, owner})

    if MapSet.size(dependents) == 0 do
      finalize_unload(state, owner, :unloaded)
    else
      fiber = %{fiber | state: :unloading}
      state = put_fiber(state, fiber)
      keys = MapSet.to_list(fiber.provides)
      state = notify_dependents(state, dependents, keys)
      state = log(state, {:deactivating, MapSet.to_list(dependents), keys})

      timer =
        Process.send_after(self(), {:dsh_unload_timeout, owner}, state.deactivate_timeout)

      pending = %{fiber: fiber, waiting: dependents, timer: timer}
      %{state | pending: Map.put(state.pending, owner, pending)}
    end
  end

  defp acknowledge(state, pid) do
    Enum.reduce(state.pending, state, fn {owner, pending}, st ->
      if MapSet.member?(pending.waiting, pid) do
        waiting = MapSet.delete(pending.waiting, pid)
        st = log(st, {:deactivated, pid})
        st = %{st | pending: Map.put(st.pending, owner, %{pending | waiting: waiting})}

        if MapSet.size(waiting) == 0 do
          finalize_unload(st, owner, :unloaded)
        else
          st
        end
      else
        st
      end
    end)
  end

  defp finalize_unload(state, owner, outcome) do
    # Map.pop's second element is the remaining pending map, not the state.
    case Map.pop(state.pending, owner) do
      {nil, pending} ->
        state = %{state | pending: pending}

        # synchronous path: the fiber is still in the registry
        case Map.get(state.fibers, owner) do
          nil -> state
          fiber -> apply_withdrawal(state, owner, fiber, outcome)
        end

      {%{fiber: fiber, timer: timer}, pending} ->
        Process.cancel_timer(timer)
        state = %{state | pending: pending}
        apply_withdrawal(state, owner, fiber, outcome)
    end
  end

  defp apply_withdrawal(state, owner, fiber, outcome) do
    state = Effect.dispose(fiber.inverses, state)
    state = log(state, {outcome, owner})
    state = %{state | fibers: Map.delete(state.fibers, owner)}
    state = demonitor_owner(state, owner)
    if Process.alive?(owner), do: send(owner, {:dsh_unloaded, owner})
    state
  end

  defp crash_withdraw(state, owner) do
    case Map.get(state.fibers, owner) do
      nil ->
        withdraw_owner_bindings(state, owner)

      fiber ->
        ordered_withdraw(state, owner, fiber)
    end
  end

  # Notify dependents and mark their mirror :unloading at the same moment
  # (the paper's L-Leave): the fiber's own transition reports drive the mirror
  # back to :inactive once its teardown completes.
  defp notify_dependents(state, dependents, keys) do
    Enum.each(dependents, fn pid -> send(pid, {:dsh_withdraw, keys}) end)

    Enum.reduce(dependents, state, fn pid, st ->
      case Map.get(st.fibers, pid) do
        nil -> st
        dep_fiber -> put_fiber(st, %{dep_fiber | state: :unloading})
      end
    end)
  end

  defp withdraw_owner_bindings(state, owner) do
    keys = for {key, pid} <- state.owners, pid == owner, do: key
    %{state | bindings: Map.drop(state.bindings, keys), owners: Map.drop(state.owners, keys)}
  end
end
