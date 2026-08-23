defmodule DshBeam.Runtime do
  @moduledoc """
  Boots the unified context and mounts an ordered list of plugin entries under
  a DynamicSupervisor. reconcile/2 diffs the desired configuration against the
  mounted entries through the Loader and applies the least disruptive change,
  reporting start failures instead of swallowing them.

  Plugins run with restart: :temporary — the orchestrator owns the lifecycle
  (the paper's model). A plugin that crashes after starting is re-injected up
  to @max_restarts times; beyond that the entry is kept as failed with
  error: :crash_loop, and a later reconcile can retry it.
  """

  use GenServer

  require Logger

  alias DshBeam.Loader

  @max_restarts 3

  @typedoc "One configuration entry: id, plugin module, config, disabled."
  @type entry :: %{id: term(), plugin: module(), config: keyword(), disabled: boolean()}

  def start_link(entries, opts) do
    GenServer.start_link(__MODULE__, entries, opts)
  end

  def context(runtime), do: GenServer.call(runtime, :context)

  def entries(runtime), do: GenServer.call(runtime, :entries)

  def reconcile(runtime, entries) do
    GenServer.call(runtime, {:reconcile, entries})
  end

  @impl true
  def init(entries) do
    {:ok, ctx} = DshBeam.Context.start_link([])
    {:ok, sup} = DynamicSupervisor.start_link(strategy: :one_for_one)
    state = %{ctx: ctx, sup: sup, entries: %{}}
    {:ok, state, {:continue, {:apply, entries}}}
  end

  @impl true
  def handle_continue({:apply, entries}, state) do
    {state, errors} = apply_entries(state, entries)

    if errors != [] do
      Logger.error("initial composition failed: #{inspect(errors)}")
    end

    {:noreply, state}
  end

  @impl true
  def handle_call(:context, _from, state), do: {:reply, state.ctx, state}

  def handle_call(:entries, _from, state), do: {:reply, state.entries, state}

  def handle_call({:reconcile, entries}, _from, state) do
    {state, errors} = apply_entries(state, entries)

    reply = if errors == [], do: :ok, else: {:error, errors}
    {:reply, reply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    case Enum.find(state.entries, fn {_id, %{pid: p}} -> p == pid end) do
      nil ->
        {:noreply, state}

      {id, %{spec: entry, restarts: n}} when n < @max_restarts ->
        Logger.warning(
          "plugin #{inspect(id)} crashed; re-injecting (attempt #{n + 1}/#{@max_restarts})"
        )

        {state, _result} = start_entry(state, entry, n + 1)
        {:noreply, state}

      {id, %{spec: entry}} ->
        Logger.error("plugin #{inspect(id)} exceeded restart limit (#{@max_restarts}); giving up")
        failed = %{spec: entry, pid: nil, restarts: @max_restarts, error: :crash_loop}
        {:noreply, %{state | entries: Map.put(state.entries, id, failed)}}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp apply_entries(state, desired) do
    current = Map.new(state.entries, fn {id, %{spec: entry}} -> {id, entry} end)
    diff = Loader.diff(current, desired)

    state = Enum.reduce(diff.stop, state, &stop_entry(&2, &1))

    {state, errors} =
      Enum.reduce(diff.restart, {state, []}, fn entry, {st, errs} ->
        st = stop_entry(st, entry.id)
        {st2, result} = start_entry(st, entry, 0)
        {st2, collect_error(result, errs)}
      end)

    {state, errors} =
      Enum.reduce(diff.start, {state, errors}, fn entry, {st, errs} ->
        {st2, result} = start_entry(st, entry, 0)
        {st2, collect_error(result, errs)}
      end)

    {state, errors}
  end

  defp collect_error(:ok, errors), do: errors
  defp collect_error({:error, reason}, errors), do: [reason | errors]

  defp start_entry(state, %{disabled: true}, _restarts), do: {state, :ok}

  defp start_entry(state, entry, restarts) do
    config = Keyword.put_new(entry.config, :id, entry.id)

    spec = %{
      id: {DshBeam.Plugin, entry.id},
      start: {entry.plugin, :start_link, [state.ctx, config]},
      restart: :temporary,
      shutdown: 5000
    }

    case DynamicSupervisor.start_child(state.sup, spec) do
      {:ok, pid} ->
        Process.monitor(pid)
        {put_entry(state, entry, pid, restarts), :ok}

      {:error, reason} ->
        Logger.warning("plugin #{inspect(entry.id)} failed to start: #{inspect(reason)}")
        failed = %{spec: entry, pid: nil, restarts: restarts, error: {:start_failed, reason}}

        {%{state | entries: Map.put(state.entries, entry.id, failed)},
         {:error, {entry.id, reason}}}
    end
  end

  defp stop_entry(state, id) do
    case Map.get(state.entries, id) do
      nil ->
        state

      %{pid: nil} ->
        %{state | entries: Map.delete(state.entries, id)}

      %{pid: pid} ->
        # DynamicSupervisor.terminate_child/2 takes the child pid, unlike the
        # static Supervisor API which takes the child id.
        case DynamicSupervisor.terminate_child(state.sup, pid) do
          :ok -> :ok
          {:error, :not_found} -> :ok
        end

        %{state | entries: Map.delete(state.entries, id)}
    end
  end

  defp put_entry(state, entry, pid, restarts) do
    %{
      state
      | entries: Map.put(state.entries, entry.id, %{spec: entry, pid: pid, restarts: restarts})
    }
  end
end
