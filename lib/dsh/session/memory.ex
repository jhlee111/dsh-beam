defmodule DshBeam.Session.Memory do
  @moduledoc """
  Session provider: an ETS-backed append-only log. Seq is assigned by the
  provider; all/1 reads events back in append order.
  """

  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  # Unlinked start: a provider resource that must outlive its owning plugin
  # process and be released by the withdrawal protocol instead.
  def start(opts) do
    GenServer.start(__MODULE__, opts)
  end

  @impl true
  def init(_opts) do
    tid = :ets.new(:dsh_session_memory, [:ordered_set, :public])
    {:ok, %{tid: tid, seq: 0, subscribers: %{}}}
  end

  @impl true
  def handle_call({:append, event}, _from, state) do
    seq = state.seq + 1
    :ets.insert(state.tid, {{seq}, event})
    notify(state.subscribers, event)
    {:reply, {:ok, seq}, %{state | seq: seq}}
  end

  @impl true
  def handle_call(:all, _from, state) do
    events = state.tid |> :ets.tab2list() |> Enum.map(fn {_seq, event} -> event end)
    {:reply, events, state}
  end

  @impl true
  def handle_call(:count, _from, state) do
    {:reply, :ets.info(state.tid, :size), state}
  end

  @impl true
  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(state.tid)
    {:reply, :ok, %{state | seq: 0}}
  end

  @impl true
  def handle_call(:subscribe, {owner, _tag}, state) do
    case state.subscribers do
      %{^owner => _ref} ->
        {:reply, :ok, state}

      _ ->
        ref = Process.monitor(owner)
        {:reply, :ok, %{state | subscribers: Map.put(state.subscribers, owner, ref)}}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | subscribers: Map.delete(state.subscribers, pid)}}
  end

  @impl true
  def terminate(_reason, state) do
    :ets.delete(state.tid)
    :ok
  end

  defp notify(subscribers, event) do
    Enum.each(subscribers, fn {pid, _ref} -> send(pid, {:dsh_session_event, event}) end)
  end
end
