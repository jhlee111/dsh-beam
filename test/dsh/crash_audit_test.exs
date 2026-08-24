defmodule CrashAuditBoomPlugin do
  @moduledoc false
  # Fails at mount: exercises the :start_failed audit path.
  use DshBeam.Plugin

  @impl DshBeam.Plugin
  def mount(_ctx, _opts) do
    raise "audit boom at mount"
  end
end

defmodule AuditCrashLoopPlugin do
  @moduledoc false
  # Plain GenServer that crashes on every start via {:continue, :crash} —
  # the same shape as the runtime's existing CrashLoopPlugin. Exercises the
  # :crashed/:crash_loop audit path (re-injection up to the limit, then
  # crash_loop).
  use GenServer

  def start_link(ctx, opts) do
    GenServer.start_link(__MODULE__, {ctx, opts})
  end

  @impl true
  def init(_args), do: {:ok, %{}, {:continue, :crash}}

  @impl true
  def handle_continue(:crash, _state), do: raise("audit boom crash")
end

defmodule DshBeam.CrashAuditTest do
  use ExUnit.Case, async: false

  defp tmp_path(label) do
    Path.join([System.tmp_dir!(), "dsh_audit_#{label}_#{System.unique_integer([:positive])}.log"])
  end

  defp wait_until(fun, timeout \\ 3000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait(fun, deadline)
  end

  defp do_wait(fun, deadline) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) > deadline do
        flunk("wait_until timed out")
      else
        Process.sleep(10)
        do_wait(fun, deadline)
      end
    end
  end

  defp read_events(path) do
    if File.exists?(path) do
      path
      |> File.stream!()
      |> Enum.map(&JSON.decode!/1)
    else
      []
    end
  end

  test "record/3 appends JSONL lines, keeps a bounded memory window, and notifies subscribers" do
    path = tmp_path("basic")
    on_exit(fn -> File.rm(path) end)

    {:ok, audit} = DshBeam.CrashAudit.start_link(path: path, max_retained: 3)
    :ok = DshBeam.CrashAudit.subscribe(audit)

    for i <- 1..5 do
      :ok = DshBeam.CrashAudit.record(audit, :crashed, {:plugin, i}, "reason #{i}")
    end

    # live fan-out (first event arrives)
    assert_receive {:crash_audit, %DshBeam.CrashAudit.Event{kind: :crashed, id: {:plugin, 1}}}

    # bounded in-memory window: only the latest 3 are kept
    assert length(DshBeam.CrashAudit.all(audit)) == 3

    assert Enum.map(DshBeam.CrashAudit.all(audit), & &1.id) == [
             {:plugin, 5},
             {:plugin, 4},
             {:plugin, 3}
           ]

    # durable file: all 5 lines, JSON-decodable, with a printable reason
    wait_until(fn -> length(read_events(path)) == 5 end)
    [first | _] = read_events(path)
    assert first["kind"] == "crashed"
    assert first["id"] == "{:plugin, 1}"
  end

  test "a runtime with an audit path records start failures and crash loops" do
    path = tmp_path("runtime")
    on_exit(fn -> File.rm(path) end)

    {:ok, runtime} = DshBeam.Runtime.start_link([], audit_path: path)
    assert is_pid(DshBeam.Runtime.audit(runtime))

    # start failure
    bad = %{id: :bad, plugin: CrashAuditBoomPlugin, config: [], disabled: false}
    assert {:error, [{:bad, _}]} = DshBeam.Runtime.reconcile(runtime, [bad])

    # crash loop: a running plugin raises on demand; re-injected 3x, then given up
    loop = %{id: :boom, plugin: AuditCrashLoopPlugin, config: [], disabled: false}
    :ok = DshBeam.Runtime.reconcile(runtime, [loop])

    wait_until(fn ->
      match?(%{boom: %{pid: nil, error: :crash_loop}}, DshBeam.Runtime.entries(runtime))
    end)

    events = read_events(path)
    kinds = Enum.map(events, & &1["kind"])

    assert "start_failed" in kinds
    assert "crashed" in kinds
    assert "crash_loop" in kinds
    assert Enum.count(events, &(&1["kind"] == "crashed")) >= 3
  end

  test "a runtime without an audit path records nothing and stays side-effect-free" do
    {:ok, runtime} = DshBeam.Runtime.start_link([], [])
    assert DshBeam.Runtime.audit(runtime) == nil

    bad = %{id: :bad, plugin: CrashAuditBoomPlugin, config: [], disabled: false}
    assert {:error, [{:bad, _}]} = DshBeam.Runtime.reconcile(runtime, [bad])

    dsh_dir = Path.join([File.cwd!(), ".dsh"])
    files = if File.dir?(dsh_dir), do: File.ls!(dsh_dir), else: []
    refute Enum.any?(files, &(&1 =~ "crash-audit"))
  end

  test "a supervised runtime is re-spawned by the supervisor after a crash" do
    path = tmp_path("supervised")
    on_exit(fn -> File.rm(path) end)

    entry = %{id: :p, plugin: DshBeam.Provider, config: [provides: %{p: 1}], disabled: false}

    {:ok, sup} =
      Supervisor.start_link(
        [
          %{
            id: :runtime,
            start: {DshBeam.Runtime, :start_link, [[entry], [audit_path: path]]},
            restart: :permanent,
            shutdown: 5000
          }
        ],
        strategy: :one_for_one
      )

    on_exit(fn ->
      if Process.alive?(sup) do
        try do
          Supervisor.stop(sup, :normal, 5000)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    [runtime] = Supervisor.which_children(sup) |> Enum.map(&elem(&1, 1))
    assert is_pid(runtime)
    %{p: %{pid: pid}} = DshBeam.Runtime.entries(runtime)
    assert is_pid(pid)

    ref = Process.monitor(runtime)
    Process.exit(runtime, :kill)
    assert_receive {:DOWN, ^ref, :process, ^runtime, :killed}, 2000

    # the supervisor restarts the runtime with a fresh pid
    wait_until(fn ->
      case Supervisor.which_children(sup) |> Enum.map(&elem(&1, 1)) do
        [pid] when is_pid(pid) -> pid != runtime
        _ -> false
      end
    end)

    [runtime2] = Supervisor.which_children(sup) |> Enum.map(&elem(&1, 1))
    assert runtime2 != runtime

    wait_until(fn ->
      match?(%{p: %{pid: pid}} when is_pid(pid), DshBeam.Runtime.entries(runtime2))
    end)

    %{p: %{pid: pid2}} = DshBeam.Runtime.entries(runtime2)
    assert is_pid(pid2)
  end
end
