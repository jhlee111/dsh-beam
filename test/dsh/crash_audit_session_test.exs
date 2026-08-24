defmodule SessionBridgeCrashPlugin do
  @moduledoc false
  # Crashes on every start via {:continue, :crash}: exercises the live
  # :crashed/:crash_loop audit path that the bridge interleaves.
  use GenServer

  def start_link(ctx, opts) do
    GenServer.start_link(__MODULE__, {ctx, opts})
  end

  @impl true
  def init(_args), do: {:ok, %{}, {:continue, :crash}}

  @impl true
  def handle_continue(:crash, _state), do: raise("bridge boom crash")
end

defmodule DshBeam.CrashAuditSessionTest do
  use ExUnit.Case, async: false

  # crash_audit resolves its audit from the runtime, so no audit pid has to be
  # threaded through the entries: the bridge depends on :crash_audit + :session.
  defp base_entries do
    [
      %{id: :session, plugin: DshBeam.Session.Plugin, config: [], disabled: false},
      %{id: :crash_audit, plugin: DshBeam.CrashAudit.Plugin, config: [], disabled: false},
      %{id: :bridge, plugin: DshBeam.CrashAudit.SessionBridge, config: [], disabled: false}
    ]
  end

  defp crash_entries do
    [%{id: :boom, plugin: SessionBridgeCrashPlugin, config: [], disabled: false}]
  end

  defp crash_audit_events(session) do
    session
    |> DshBeam.Session.all()
    |> Enum.filter(&(&1["role"] == "crash_audit"))
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

  defp tmp_path(label) do
    Path.join([
      System.tmp_dir!(),
      "dsh_bridge_#{label}_#{System.unique_integer([:positive])}.log"
    ])
  end

  defp with_runtime(entries, fun) do
    path = tmp_path("audit")
    on_exit(fn -> File.rm(path) end)
    {:ok, runtime} = DshBeam.Runtime.start_link(entries, audit_path: path)
    on_exit(fn -> if Process.alive?(runtime), do: GenServer.stop(runtime, :normal, 5000) end)
    fun.(runtime)
  end

  test "crash events interleave into the session log while the bridge is active" do
    with_runtime(base_entries() ++ crash_entries(), fn runtime ->
      ctx = DshBeam.Runtime.context(runtime)
      {:ok, session} = DshBeam.Context.get(ctx, :session)

      # the bridge is active once both deps are present and the boom plugin
      # has crash-looped (live :crashed + :crash_loop events)
      wait_until(fn ->
        match?(%{boom: %{pid: nil, error: :crash_loop}}, DshBeam.Runtime.entries(runtime))
      end)

      events = crash_audit_events(session)
      kinds = Enum.map(events, & &1["kind"])

      assert "crashed" in kinds
      assert "crash_loop" in kinds
      assert Enum.count(events, &(&1["kind"] == "crashed")) >= 3

      # every row is JSON-shaped and carries the reason (the first crash keeps
      # the full stacktrace; re-injections may carry a bare :noproc atom)
      event = Enum.find(events, &(&1["kind"] == "crash_loop"))
      assert event["id"] == ":boom"

      assert event["reason"] == :noproc or
               (is_binary(event["reason"]) and event["reason"] =~ "bridge boom crash")

      assert is_integer(event["timestamp"])
    end)
  end

  test "the bridge drains missed events when it activates after the crash" do
    # start WITHOUT the bridge: session + crash_audit + boom (boom crash-loops)
    with_runtime(base_entries() -- [bridge_entry()], fn runtime ->
      ctx = DshBeam.Runtime.context(runtime)

      :ok =
        DshBeam.Runtime.reconcile(
          runtime,
          (base_entries() -- [bridge_entry()]) ++ crash_entries()
        )

      wait_until(fn ->
        match?(%{boom: %{pid: nil, error: :crash_loop}}, DshBeam.Runtime.entries(runtime))
      end)

      # mount the bridge afterwards: it must drain the retained window (boom
      # is dropped so convergence cannot restart it and mint NEW crashes)
      :ok = DshBeam.Runtime.reconcile(runtime, base_entries())

      {:ok, session} = DshBeam.Context.get(ctx, :session)
      wait_until(fn -> Enum.count(crash_audit_events(session)) >= 4 end)

      kinds = crash_audit_events(session) |> Enum.map(& &1["kind"])
      assert "crashed" in kinds
      assert "crash_loop" in kinds
    end)
  end

  defp bridge_entry do
    %{id: :bridge, plugin: DshBeam.CrashAudit.SessionBridge, config: [], disabled: false}
  end

  test "re-activating the bridge does not duplicate existing rows" do
    with_runtime(base_entries() ++ crash_entries(), fn runtime ->
      ctx = DshBeam.Runtime.context(runtime)
      {:ok, session} = DshBeam.Context.get(ctx, :session)

      wait_until(fn ->
        match?(%{boom: %{pid: nil, error: :crash_loop}}, DshBeam.Runtime.entries(runtime))
      end)

      count = crash_audit_events(session) |> length()
      assert count >= 4

      # stop the crash-looping boom cleanly (no NEW crash events), then swap
      # the bridge out and back in: the drain must skip rows that are already
      # in the session (same timestamp/kind/id)
      :ok = DshBeam.Runtime.reconcile(runtime, base_entries())
      wait_until(fn -> crash_audit_events(session) |> length() == count end)

      :ok = DshBeam.Runtime.reconcile(runtime, Enum.reject(base_entries(), &(&1.id == :bridge)))
      :ok = DshBeam.Runtime.reconcile(runtime, base_entries())

      wait_until(fn ->
        match?(%{bridge: %{pid: pid}} when is_pid(pid), DshBeam.Runtime.entries(runtime))
      end)

      assert crash_audit_events(session) |> length() == count
    end)
  end
end
