defmodule DshBeam.Runtime do
  @moduledoc """
  Boots the unified context and mounts an ordered list of plugin entries under
  a DynamicSupervisor. reconcile/2 diffs the desired configuration against the
  mounted entries through the Loader and applies the least disruptive change,
  reporting start failures instead of swallowing them.

  Plugins run with restart: :temporary — the orchestrator owns the lifecycle
  (the paper's model). Re-injection after a crash is asynchronous with
  backoff: a crashed provider's withdrawal can still be draining its
  dependents when the replacement registers, so an :already_provided start
  failure is retried (bounded, exponential) instead of consuming the restart
  budget. Intentional exits (:normal, :shutdown, an external :kill) are not
  re-injected — they are recorded and left for a later reconcile, which
  re-asserts every desired entry that is not running. Crashes re-inject up to
  @max_restarts times; beyond that the entry is kept with error: :crash_loop.
  """

  use GenServer

  require Logger

  alias DshBeam.Loader

  @max_restarts 3
  @reinject_backoff_base_ms 10
  @reinject_backoff_max_ms 50
  @withdraw_retry_max 6
  @withdraw_retry_base_ms 25
  @withdraw_retry_max_ms 800

  @typedoc "One configuration entry: id, plugin module, config, disabled."
  @type entry :: %{id: term(), plugin: module(), config: keyword(), disabled: boolean()}

  def start_link(entries, opts) do
    # :settings_path and :audit_path are dsh-beam options, not GenServer
    # options: thread them into the init data so the settings store can
    # persist overrides to disk and the crash audit trail can land next to
    # it. When absent (the default, and what tests use) they stay in-memory /
    # default-path respectively.
    GenServer.start_link(
      __MODULE__,
      {entries, Keyword.get(opts, :settings_path), Keyword.get(opts, :audit_path)},
      Keyword.drop(opts, [:settings_path, :audit_path])
    )
  end

  def context(runtime), do: GenServer.call(runtime, :context)

  def entries(runtime), do: GenServer.call(runtime, :entries)

  def settings(runtime), do: GenServer.call(runtime, :settings)

  @doc "The crash audit GenServer owned by this runtime (nil when none was configured)."
  def audit(runtime), do: GenServer.call(runtime, :audit)

  def reconcile(runtime, entries) do
    GenServer.call(runtime, {:reconcile, entries})
  end

  @doc """
  Re-mount one entry with its current config. A settings save changes the
  resolved config (typed-settings overrides are merged at mount), so this
  forces the running plugin to pick up the new value without a full reconcile.
  """
  def restart(runtime, id) do
    GenServer.call(runtime, {:restart, id})
  end

  @doc """
  Subscribe the calling process to entry changes. Every change to the entry
  map (start, stop, crash, re-injection, crash loop) is fanned out as
  {:dsh_runtime_event, {id, record_or_removed}}. The subscription is removed
  when the subscriber dies.
  """
  def subscribe(runtime), do: GenServer.call(runtime, :subscribe)

  @impl true
  def init({entries, settings_path, audit_path}) do
    {:ok, ctx} = DshBeam.Context.start_link([])
    {:ok, sup} = DynamicSupervisor.start_link(strategy: :one_for_one)
    {:ok, settings} = DshBeam.Settings.start_link(path: settings_path)

    # The crash audit trail is opt-in (the console passes :audit_path): when
    # absent the runtime records nothing, so library users and tests stay
    # side-effect-free. The audit is linked to the runtime and dies with it —
    # the durable record is the file, which the next runtime re-attaches to.
    audit = if audit_path, do: start_audit!(audit_path), else: nil

    state = %{
      ctx: ctx,
      sup: sup,
      settings: settings,
      audit: audit,
      entries: %{},
      subscribers: %{}
    }

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

  def handle_call(:settings, _from, state), do: {:reply, state.settings, state}

  def handle_call(:audit, _from, state), do: {:reply, state.audit, state}

  def handle_call(:subscribe, {owner, _tag}, state) do
    case state.subscribers do
      %{^owner => _ref} ->
        {:reply, :ok, state}

      _ ->
        ref = Process.monitor(owner)
        {:reply, :ok, %{state | subscribers: Map.put(state.subscribers, owner, ref)}}
    end
  end

  def handle_call({:reconcile, entries}, _from, state) do
    {state, errors} = apply_entries(state, entries)

    reply = if errors == [], do: :ok, else: {:error, errors}
    {:reply, reply, state}
  end

  def handle_call({:restart, id}, _from, state) do
    case Map.get(state.entries, id) do
      %{spec: spec, pid: pid} when is_pid(pid) ->
        state = stop_entry(state, id)
        {state, errors} = start_and_collect(state, spec, [])

        reply = if errors == [], do: :ok, else: {:error, errors}
        {:reply, reply, state}

      _ ->
        {:reply, :not_found, state}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    state = %{state | subscribers: Map.delete(state.subscribers, pid)}

    case Enum.find(state.entries, fn {_id, %{pid: p}} -> p == pid end) do
      nil ->
        {:noreply, state}

      {id, rec} ->
        {:noreply, handle_exit(state, id, rec, reason)}
    end
  end

  def handle_info({:dsh_reinject, id, attempt, withdraw_retries}, state) do
    case Map.get(state.entries, id) do
      nil ->
        # a reconcile removed the entry while the timer was pending: stale
        {:noreply, state}

      %{timer: nil} ->
        # a reconcile restarted the entry while the timer was pending: stale
        {:noreply, state}

      rec ->
        state = put_record(state, id, %{rec | timer: nil})
        {state, result} = start_entry(state, rec.spec, attempt)

        case result do
          :ok ->
            {:noreply, state}

          {:error, {_id, reason}} ->
            cond do
              withdraw_retries < @withdraw_retry_max and withdraw_race?(reason) ->
                {:noreply, arm_withdraw_retry(state, rec.spec, attempt, withdraw_retries + 1)}

              true ->
                {:noreply, state}
            end
        end
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # The exit reason tells an intentional stop apart from a crash: the fiber's
  # graceful termination (:normal/:shutdown) and an external kill (:killed)
  # are recorded and left for the orchestrator's reconcile, while abnormal
  # exits re-inject with backoff.
  defp handle_exit(state, id, rec, reason) do
    cond do
      intentional_exit?(reason) ->
        Logger.warning("plugin #{inspect(id)} exited (#{inspect(reason)}); not re-injecting")
        audit_record(state, :exited, id, reason)
        put_record(state, id, %{rec | pid: nil, timer: nil, error: {:exited, reason}})

      rec.restarts < @max_restarts ->
        attempt = rec.restarts + 1

        Logger.warning(
          "plugin #{inspect(id)} crashed; re-injecting (attempt #{attempt}/#{@max_restarts})"
        )

        audit_record(state, :crashed, id, reason)

        timer =
          Process.send_after(self(), {:dsh_reinject, id, attempt, 0}, reinject_delay(attempt))

        put_record(state, id, %{rec | pid: nil, timer: timer, error: {:crashed, reason}})

      true ->
        Logger.error("plugin #{inspect(id)} exceeded restart limit (#{@max_restarts}); giving up")
        audit_record(state, :crash_loop, id, reason)
        put_record(state, id, %{rec | pid: nil, timer: nil, error: :crash_loop})
    end
  end

  defp intentional_exit?(reason) do
    reason in [:normal, :shutdown, :killed] or match?({:shutdown, _}, reason)
  end

  # A start failure with :already_provided means the previous instance's
  # withdrawal is still draining its dependents (the paper's L-Unload guard
  # keeps the binding alive for committed reads). Retrying with a bounded
  # backoff lets the withdrawal finish without consuming the restart budget.
  defp withdraw_race?({:already_provided, _keys}), do: true
  defp withdraw_race?(:already_provided), do: true
  defp withdraw_race?(_reason), do: false

  defp reinject_delay(attempt) do
    min(@reinject_backoff_base_ms * Integer.pow(2, attempt - 1), @reinject_backoff_max_ms)
  end

  defp withdraw_retry_delay(n) do
    min(@withdraw_retry_base_ms * Integer.pow(2, n - 1), @withdraw_retry_max_ms)
  end

  defp arm_withdraw_retry(state, entry, attempt, retry_n) do
    timer =
      Process.send_after(
        self(),
        {:dsh_reinject, entry.id, attempt, retry_n},
        withdraw_retry_delay(retry_n)
      )

    update_record(state, entry.id, &%{&1 | timer: timer, error: :withdraw_pending})
  end

  defp apply_entries(state, desired) do
    current = Map.new(state.entries, fn {id, %{spec: entry}} -> {id, entry} end)
    diff = Loader.diff(current, desired)

    state = Enum.reduce(diff.stop, state, &stop_entry(&2, &1))

    {state, errors} =
      Enum.reduce(diff.restart, {state, []}, fn entry, {st, errs} ->
        st = stop_entry(st, entry.id)
        start_and_collect(st, entry, errs)
      end)

    {state, errors} =
      Enum.reduce(diff.start, {state, errors}, fn entry, {st, errs} ->
        start_and_collect(st, entry, errs)
      end)

    # Convergence (review finding H2): a reconcile re-asserts every desired
    # entry that is not running — failed starts, killed plugins, crash loops —
    # unless a re-injection is already pending for it.
    reassert =
      for {id, rec} <- state.entries,
          rec.pid == nil,
          rec.timer == nil,
          entry = Enum.find(desired, &(&1.id == id)),
          not entry.disabled,
          not Enum.any?(diff.start ++ diff.restart, &(&1.id == id)),
          do: entry

    Enum.reduce(reassert, {state, errors}, fn entry, {st, errs} ->
      st = stop_entry(st, entry.id)
      start_and_collect(st, entry, errs)
    end)
  end

  defp start_and_collect(st, entry, errs) do
    {st, result} = start_entry(st, entry, 0)
    errs = collect_error(result, errs)

    st =
      case result do
        # the previous instance is still mid-withdrawal: retry in the
        # background instead of failing for good
        {:error, {_id, reason}} ->
          if withdraw_race?(reason), do: arm_withdraw_retry(st, entry, 0, 1), else: st

        :ok ->
          st
      end

    {st, errs}
  end

  defp collect_error(:ok, errors), do: errors
  defp collect_error({:error, reason}, errors), do: [reason | errors]

  defp start_entry(state, %{disabled: true} = entry, _restarts) do
    # A disabled entry stays in the desired composition: record it without a
    # fiber, so a later reconcile can re-enable it and the console can show it
    # as "disabled" instead of gone. The reassert pass skips disabled entries,
    # so this record is never started behind the operator's back.
    {put_record(state, entry.id, %{spec: entry, pid: nil, restarts: 0, error: nil, timer: nil}),
     :ok}
  end

  defp start_entry(state, entry, restarts) do
    # Lay the typed-settings overrides (resolved defaults + any saved
    # override) under the entry config, so a setting saved through the
    # console actually reaches the running plugin's mount config while an
    # explicit entry config still wins.
    config =
      settings_overrides(state.settings, entry.plugin)
      |> Keyword.merge(entry.config)
      |> Keyword.put_new(:id, entry.id)
      |> Keyword.put_new(:runtime, self())
      |> Keyword.put_new(:audit, state.audit)

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
        audit_record(state, :start_failed, entry.id, reason)

        failed = %{
          spec: entry,
          pid: nil,
          restarts: restarts,
          error: {:start_failed, reason},
          timer: nil
        }

        {%{state | entries: Map.put(state.entries, entry.id, failed)},
         {:error, {entry.id, reason}}}
    end
  end

  defp stop_entry(state, id) do
    case Map.get(state.entries, id) do
      nil ->
        state

      rec ->
        if is_reference(rec.timer), do: Process.cancel_timer(rec.timer)

        if is_pid(rec.pid) do
          # DynamicSupervisor.terminate_child/2 takes the child pid, unlike the
          # static Supervisor API which takes the child id.
          case DynamicSupervisor.terminate_child(state.sup, rec.pid) do
            :ok -> :ok
            {:error, :not_found} -> :ok
          end
        end

        state
        |> Map.update!(:entries, &Map.delete(&1, id))
        |> notify({id, :removed})
    end
  end

  defp put_entry(state, entry, pid, restarts) do
    put_record(state, entry.id, %{
      spec: entry,
      pid: pid,
      restarts: restarts,
      error: nil,
      timer: nil
    })
  end

  defp put_record(state, id, rec) do
    state
    |> Map.update!(:entries, &Map.put(&1, id, rec))
    |> notify({id, rec})
  end

  defp update_record(state, id, fun) do
    case Map.get(state.entries, id) do
      nil -> state
      rec -> put_record(state, id, fun.(rec))
    end
  end

  defp notify(state, event) do
    Enum.each(state.subscribers, fn {pid, _ref} ->
      send(pid, {:dsh_runtime_event, event})
    end)

    state
  end

  # Resolve every declared setting of a plugin from the settings store; the
  # resolved values become mount config overrides (entry config already wins).
  defp settings_overrides(store, plugin) do
    for setting <- DshBeam.Plugin.settings(plugin),
        {:ok, value} <- [DshBeam.Settings.get(store, plugin, setting.name)],
        into: [],
        do: {setting.name, value}
  end

  defp start_audit!(path) do
    {:ok, audit} = DshBeam.CrashAudit.start_link(path: path)
    audit
  end

  defp audit_record(%{audit: nil}, _kind, _id, _reason), do: :ok

  defp audit_record(%{audit: audit}, kind, id, reason) do
    DshBeam.CrashAudit.record(audit, kind, id, reason)
  end
end
