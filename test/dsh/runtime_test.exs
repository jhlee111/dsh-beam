defmodule TeardownProbeConsumer do
  @moduledoc false
  use DshBeam.Plugin

  def result(pid), do: :gen_statem.call(pid, :result)

  @impl DshBeam.Plugin
  def mount(_ctx, opts) do
    {:ok, [:session], %{}, %{parent: Keyword.fetch!(opts, :parent), result: nil}}
  end

  @impl DshBeam.Plugin
  def handle_dsh_ready(state) do
    send(state.extra.parent, {:probe_registered, self(), state.fiber_state, state.view})
    {:ok, state}
  end

  @impl DshBeam.Plugin
  def handle_dsh_withdraw(_keys, state) do
    # During our own teardown the provider has not withdrawn yet: the session
    # in our committed view is still alive and readable.
    result = DshBeam.Session.count(state.view.session)
    send(state.extra.parent, {:probe_teardown_read, result})
    {:ok, %{state | extra: %{state.extra | result: {:read_during_teardown, result}}}}
  end

  @impl true
  def handle_event({:call, from}, :result, _state, data) do
    {:keep_state_and_data, [{:reply, from, data.extra.result}]}
  end
end

defmodule DshBeam.RuntimeTest do
  use ExUnit.Case, async: false

  defp session_entry,
    do: %{id: :session, plugin: DshBeam.Session.Plugin, config: [], disabled: false}

  defp consumer_entry do
    %{
      id: :consumer,
      plugin: DshBeam.Consumer,
      config: [deps: [:session], parent: self()],
      disabled: false
    }
  end

  test "boots an ordered composition; the consumer resolves and uses the session" do
    {:ok, runtime} = DshBeam.Runtime.start_link([session_entry(), consumer_entry()], [])

    assert_receive {:consumer_registered, :consumer, consumer, :active, %{session: session}}, 2000
    assert is_pid(session)

    assert {:ok, 1} = DshBeam.Session.append(session, %{"role" => "user", "text" => "hi"})
    assert {:ok, 2} = DshBeam.Session.append(session, %{"role" => "assistant", "text" => "hello"})

    assert DshBeam.Session.all(session) == [
             %{"role" => "user", "text" => "hi"},
             %{"role" => "assistant", "text" => "hello"}
           ]

    assert DshBeam.Consumer.view(consumer) == %{session: session}
    assert DshBeam.Runtime.entries(runtime) |> Map.keys() == [:session, :consumer]
  end

  test "removing the provider deactivates the dependent before withdrawal" do
    {:ok, runtime} = DshBeam.Runtime.start_link([session_entry(), consumer_entry()], [])
    ctx = DshBeam.Runtime.context(runtime)
    assert_receive {:consumer_registered, :consumer, consumer, :active, _view}, 2000

    :ok = DshBeam.Runtime.reconcile(runtime, [consumer_entry()])

    history = DshBeam.Context.history(ctx)
    deactivated = Enum.find_index(history, &match?({:deactivated, pid} when pid == consumer, &1))
    unloaded = Enum.find_index(history, &match?({:unloaded, _pid}, &1))

    assert deactivated != nil
    assert unloaded != nil
    assert deactivated < unloaded

    assert_receive {:consumer_deactivated, :consumer, ^consumer, [:session], _view}, 2000
    assert DshBeam.Context.get(ctx, :session) == :not_found
    assert DshBeam.Consumer.state(consumer) == :inactive
  end

  test "a provider swap reactivates only the dependent" do
    sibling_entry = %{
      id: :sibling,
      plugin: DshBeam.Provider,
      config: [provides: %{storage: :live}],
      disabled: false
    }

    sibling_consumer_entry = %{
      id: :sibling_consumer,
      plugin: DshBeam.Consumer,
      config: [deps: [:storage], parent: self()],
      disabled: false
    }

    {:ok, runtime} =
      DshBeam.Runtime.start_link(
        [session_entry(), consumer_entry(), sibling_entry, sibling_consumer_entry],
        []
      )

    ctx = DshBeam.Runtime.context(runtime)

    assert_receive {:consumer_registered, :consumer, consumer, :active, _}, 2000
    assert_receive {:consumer_registered, :sibling_consumer, sibling, :active, _}, 2000

    :ok =
      DshBeam.Runtime.reconcile(runtime, [consumer_entry(), sibling_entry, sibling_consumer_entry])

    assert_receive {:consumer_deactivated, :consumer, ^consumer, [:session], _view}, 2000
    assert DshBeam.Consumer.state(consumer) == :inactive
    assert DshBeam.Consumer.state(sibling) == :active

    path = Path.join(System.tmp_dir!(), "dsh_swap_#{System.unique_integer([:positive])}.jsonl")
    on_exit(fn -> File.rm(path) end)

    new_session_entry = %{
      id: :session,
      plugin: DshBeam.Session.Plugin,
      config: [provider: DshBeam.Session.File, path: path],
      disabled: false
    }

    :ok =
      DshBeam.Runtime.reconcile(runtime, [
        new_session_entry,
        consumer_entry(),
        sibling_entry,
        sibling_consumer_entry
      ])

    assert_receive {:consumer_activated, :consumer, ^consumer, [:session]}, 2000
    assert DshBeam.Consumer.state(consumer) == :active
    assert DshBeam.Consumer.state(sibling) == :active

    assert {:ok, session} = DshBeam.Context.get(ctx, :session)
    assert DshBeam.Session.count(session) == 0
  end

  test "a dependent still reads its committed view during its own teardown" do
    probe_entry = %{
      id: :probe,
      plugin: TeardownProbeConsumer,
      config: [parent: self()],
      disabled: false
    }

    {:ok, runtime} = DshBeam.Runtime.start_link([session_entry(), probe_entry], [])

    assert_receive {:probe_registered, probe, :active, %{session: session}}, 2000
    assert {:ok, 1} = DshBeam.Session.append(session, "one")
    assert {:ok, 2} = DshBeam.Session.append(session, "two")

    :ok = DshBeam.Runtime.reconcile(runtime, [probe_entry])

    assert_receive {:probe_teardown_read, 2}, 2000
    assert TeardownProbeConsumer.result(probe) == {:read_during_teardown, 2}
  end

  test "a crashed provider's resource survives until dependents drained (ordered shutdown)" do
    # composed directly (no Runtime): the provider crash must not take the
    # resource down before the dependent's teardown read completes
    {:ok, ctx} = DshBeam.Context.start_link([])

    {:ok, plugin} = DshBeam.Session.Plugin.start_link(ctx, id: :session)
    {:ok, probe} = TeardownProbeConsumer.start_link(ctx, id: :probe, parent: self())

    assert_receive {:probe_registered, ^probe, :active, %{session: session}}, 2000
    assert {:ok, 1} = DshBeam.Session.append(session, "one")
    assert {:ok, 2} = DshBeam.Session.append(session, "two")

    # watch the resource: it must outlive the provider crash and die only
    # after the dependent's teardown completes
    ref = Process.monitor(session)

    Process.unlink(plugin)
    Process.exit(plugin, :kill)

    assert_receive {:probe_teardown_read, 2}, 2000
    wait_until(fn -> DshBeam.Context.get(ctx, :session) == :not_found end)

    assert_receive {:DOWN, ^ref, :process, ^session, _reason}, 2000
  end

  test "a start failure is reported instead of swallowed (A-H2 regression)" do
    {:ok, runtime} = DshBeam.Runtime.start_link([], [])

    entry = %{id: :bad, plugin: FailOnStartPlugin, config: [], disabled: false}

    assert {:error, [{:bad, _reason}]} = DshBeam.Runtime.reconcile(runtime, [entry])
    assert %{bad: %{pid: nil}} = DshBeam.Runtime.entries(runtime)
  end

  test "a crashing plugin is re-injected up to the restart limit, then given up" do
    {:ok, runtime} = DshBeam.Runtime.start_link([], [])

    entry = %{id: :loop, plugin: CrashLoopPlugin, config: [], disabled: false}
    :ok = DshBeam.Runtime.reconcile(runtime, [entry])

    # re-injection is asynchronous (backoff), so wait for the terminal state
    wait_until(fn ->
      match?(%{loop: %{pid: nil, error: :crash_loop}}, DshBeam.Runtime.entries(runtime))
    end)
  end

  test "a crashed provider with a slow-draining dependent is re-injected after the withdrawal" do
    provider_entry = %{id: :p, plugin: CrashableProvider, config: [], disabled: false}

    consumer_entry = %{
      id: :slow,
      plugin: SlowDrainConsumer,
      config: [deps: [:crashable], parent: self(), drain_ms: 300],
      disabled: false
    }

    {:ok, runtime} = DshBeam.Runtime.start_link([provider_entry, consumer_entry], [])
    ctx = DshBeam.Runtime.context(runtime)

    assert_receive {:slow_registered, slow, :active}, 2000

    %{p: %{pid: crashed}} = DshBeam.Runtime.entries(runtime)
    catch_exit(:gen_statem.call(crashed, :crash))

    # The dependent drains for 300ms; the re-injection must wait out the
    # withdrawal instead of burning the restart budget on :already_provided.
    wait_until(fn ->
      match?(
        %{p: %{pid: pid, restarts: 1, error: nil}} when is_pid(pid),
        DshBeam.Runtime.entries(runtime)
      )
    end)

    assert %{p: %{pid: revived}} = DshBeam.Runtime.entries(runtime)
    refute revived == crashed

    assert {:ok, :up} = DshBeam.Context.get(ctx, :crashable)
    wait_until(fn -> DshBeam.Plugin.fiber_state(slow) == :active end)

    # the crash path still honored the guard: dependent drained before unload
    history = DshBeam.Context.history(ctx)
    deactivated = Enum.find_index(history, &match?({:deactivated, pid} when pid == slow, &1))
    unloaded = Enum.find_index(history, &match?({:unloaded, _pid}, &1))
    assert deactivated != nil and unloaded != nil and deactivated < unloaded
  end

  test "an intentionally killed plugin stays down; a reconcile re-asserts it" do
    {:ok, runtime} = DshBeam.Runtime.start_link([], [])
    ctx = DshBeam.Runtime.context(runtime)

    entry = %{id: :k, plugin: DshBeam.Provider, config: [provides: %{k: 1}], disabled: false}
    :ok = DshBeam.Runtime.reconcile(runtime, [entry])

    %{k: %{pid: pid}} = DshBeam.Runtime.entries(runtime)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 2000

    wait_until(fn -> match?(%{k: %{pid: nil}}, DshBeam.Runtime.entries(runtime)) end)

    # a crash would already be re-injected here (first backoff is ~10ms);
    # the kill must be distinguishable and left for the orchestrator
    Process.sleep(120)
    assert %{k: %{pid: nil, error: {:exited, :killed}}} = DshBeam.Runtime.entries(runtime)

    :ok = DshBeam.Runtime.reconcile(runtime, [entry])

    wait_until(fn ->
      match?(%{k: %{pid: p}} when is_pid(p), DshBeam.Runtime.entries(runtime))
    end)

    assert {:ok, 1} = DshBeam.Context.get(ctx, :k)
  end

  test "a disabled entry stays in the desired composition without a fiber" do
    {:ok, runtime} = DshBeam.Runtime.start_link([], [])

    entry = %{id: :k, plugin: DshBeam.Provider, config: [provides: %{k: 1}], disabled: true}
    :ok = DshBeam.Runtime.reconcile(runtime, [entry])

    # the entry is recorded (disabled), but no fiber runs and nothing binds
    assert %{k: %{spec: %{disabled: true}, pid: nil}} = DshBeam.Runtime.entries(runtime)
    assert DshBeam.Context.get(DshBeam.Runtime.context(runtime), :k) == :not_found

    # re-enabling starts the fiber; disabling again stops it and keeps the entry
    :ok = DshBeam.Runtime.reconcile(runtime, [%{entry | disabled: false}])
    assert %{k: %{spec: %{disabled: false}, pid: pid}} = DshBeam.Runtime.entries(runtime)
    assert is_pid(pid)

    :ok = DshBeam.Runtime.reconcile(runtime, [%{entry | disabled: true}])
    assert %{k: %{spec: %{disabled: true}, pid: nil}} = DshBeam.Runtime.entries(runtime)
  end

  test "the quiescent state is a function of the final configuration (confluence)" do
    entry_a = %{
      id: :a,
      plugin: DshBeam.Provider,
      config: [provides: %{alpha: 1}],
      disabled: false
    }

    entry_b = %{id: :b, plugin: DshBeam.Provider, config: [provides: %{beta: 2}], disabled: false}

    # path 1: a, then a+b
    {:ok, r1} = DshBeam.Runtime.start_link([], [])
    :ok = DshBeam.Runtime.reconcile(r1, [entry_a])
    :ok = DshBeam.Runtime.reconcile(r1, [entry_a, entry_b])

    # path 2: b, then a+b
    {:ok, r2} = DshBeam.Runtime.start_link([], [])
    :ok = DshBeam.Runtime.reconcile(r2, [entry_b])
    :ok = DshBeam.Runtime.reconcile(r2, [entry_a, entry_b])

    # from scratch
    {:ok, r3} = DshBeam.Runtime.start_link([entry_a, entry_b], [])

    # a canonical state: binding keys and fiber id/state summaries (pids differ)
    canonical = fn runtime ->
      %{bindings: bindings, fibers: fibers} =
        DshBeam.Context.snapshot(DshBeam.Runtime.context(runtime))

      fiber_summary =
        fibers |> Map.values() |> Enum.map(fn f -> {f.id, f.state} end) |> Enum.sort()

      %{bindings: bindings |> Map.keys() |> Enum.sort(), fibers: fiber_summary}
    end

    expected = canonical.(r3)
    assert canonical.(r1) == expected
    assert canonical.(r2) == expected
  end

  test "concurrent reconciles to one configuration converge without corruption" do
    {:ok, runtime} = DshBeam.Runtime.start_link([], [])

    entry = %{id: :x, plugin: DshBeam.Provider, config: [provides: %{omega: 1}], disabled: false}

    tasks =
      for _ <- 1..10 do
        Task.async(fn -> DshBeam.Runtime.reconcile(runtime, [entry]) end)
      end

    assert Enum.all?(Task.await_many(tasks, 5000), &(&1 == :ok))

    ctx = DshBeam.Runtime.context(runtime)
    assert DshBeam.Context.get(ctx, :omega) == {:ok, 1}
  end

  test "concurrent use during a provider swap converges to the new provider" do
    path =
      Path.join(System.tmp_dir!(), "dsh_confluence_#{System.unique_integer([:positive])}.jsonl")

    on_exit(fn -> File.rm(path) end)

    new_session_entry = %{
      id: :session,
      plugin: DshBeam.Session.Plugin,
      config: [provider: DshBeam.Session.File, path: path],
      disabled: false
    }

    {:ok, runtime} = DshBeam.Runtime.start_link([session_entry(), consumer_entry()], [])
    ctx = DshBeam.Runtime.context(runtime)

    assert_receive {:consumer_registered, :consumer, consumer, :active, _view}, 2000

    # a concurrent user keeps appending through the swap window
    writer =
      Task.async(fn ->
        for i <- 1..200 do
          case DshBeam.Context.get(ctx, :session) do
            {:ok, session} when is_pid(session) ->
              try do
                DshBeam.Session.append(session, i)
              catch
                # the old session dies mid-swap; a failed append is expected
                :exit, _ -> :ok
              end

            :not_found ->
              :ok
          end

          Process.sleep(1)
        end

        :done
      end)

    :ok = DshBeam.Runtime.reconcile(runtime, [consumer_entry()])
    :ok = DshBeam.Runtime.reconcile(runtime, [new_session_entry, consumer_entry()])

    assert_receive {:consumer_activated, :consumer, ^consumer, [:session]}, 2000
    assert Task.await(writer, 5000) == :done

    wait_until(fn ->
      match?({:ok, session} when is_pid(session), DshBeam.Context.get(ctx, :session))
    end)

    assert {:ok, new_session} = DshBeam.Context.get(ctx, :session)
    assert DshBeam.Session.count(new_session) >= 0
    assert DshBeam.Consumer.view(consumer) == %{session: new_session}
  end

  defp wait_until(fun), do: wait_until(fun, 400)

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

defmodule FailOnStartPlugin do
  @moduledoc false
  use GenServer

  def start_link(ctx, opts) do
    GenServer.start_link(__MODULE__, {ctx, opts})
  end

  @impl true
  def init(_args), do: raise("cannot start")
end

defmodule CrashLoopPlugin do
  @moduledoc false
  use GenServer

  def start_link(ctx, opts) do
    GenServer.start_link(__MODULE__, {ctx, opts})
  end

  @impl true
  def init(_args), do: {:ok, %{}, {:continue, :crash}}

  @impl true
  def handle_continue(:crash, _state), do: raise("boom")
end

defmodule CrashableProvider do
  @moduledoc false
  use DshBeam.Plugin

  @impl DshBeam.Plugin
  def mount(_ctx, _opts) do
    {:ok, [], %{crashable: :up}, %{}}
  end

  @impl true
  def handle_event({:call, _from}, :crash, _state, _data), do: raise("provider crash")
end

defmodule SlowDrainConsumer do
  @moduledoc false
  use DshBeam.Plugin

  @impl DshBeam.Plugin
  def mount(_ctx, opts) do
    extra = %{parent: Keyword.get(opts, :parent), drain_ms: Keyword.fetch!(opts, :drain_ms)}
    {:ok, Keyword.fetch!(opts, :deps), %{}, extra}
  end

  @impl DshBeam.Plugin
  def handle_dsh_ready(state) do
    if state.extra.parent,
      do: send(state.extra.parent, {:slow_registered, self(), state.fiber_state})

    {:ok, state}
  end

  @impl DshBeam.Plugin
  def handle_dsh_withdraw(_keys, state) do
    # slow teardown: keeps the provider's binding in withdrawal long enough
    # for an immediate re-injection to race it
    Process.sleep(state.extra.drain_ms)
    {:ok, state}
  end
end
