defmodule DshBeam.Session.File do
  @moduledoc """
  Session provider: a JSONL append-only log. Writes are durable — outside the
  revertible-effect boundary (paper §6.1) — so recovery here is the file's own
  history, not an inverse.
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
  def init(opts) do
    path = Keyword.fetch!(opts, :path)

    events =
      if File.exists?(path) do
        path |> File.stream!() |> Enum.map(&decode_line/1)
      else
        File.write!(path, "")
        []
      end

    header = %{
      title: Keyword.get(opts, :title, "untitled session"),
      cwd: Keyword.get(opts, :cwd)
    }

    {:ok, %{path: path, seq: length(events), header: header, subscribers: %{}}}
  end

  @impl true
  def handle_call({:append, event}, _from, state) do
    seq = state.seq + 1

    # File.write writes the raw UTF-8 bytes (Elixir strings are already UTF-8),
    # unlike the previous File.open + IO.puts path, which opened a latin1
    # device and failed to transcode non-ASCII (e.g. Korean) content.
    File.write(state.path, JSON.encode!(event) <> "\n", [:append])

    notify(state.subscribers, event)
    {:reply, {:ok, seq}, %{state | seq: seq}}
  end

  @impl true
  def handle_call(:all, _from, state) do
    events = state.path |> File.stream!() |> Enum.map(&decode_line/1)
    {:reply, events, state}
  end

  @impl true
  def handle_call(:count, _from, state) do
    {:reply, state.path |> File.stream!() |> Enum.count(), state}
  end

  @impl true
  def handle_call(:clear, _from, state) do
    File.write!(state.path, "")
    {:reply, :ok, %{state | seq: 0}}
  end

  @impl true
  def handle_call(:header, _from, state) do
    {:reply, state.header, state}
  end

  @impl true
  def handle_call({:set_header, header}, _from, state) do
    {:reply, :ok, %{state | header: Map.merge(state.header, header)}}
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

  defp notify(subscribers, event) do
    Enum.each(subscribers, fn {pid, _ref} -> send(pid, {:dsh_session_event, event}) end)
  end

  defp decode_line(line) do
    line |> String.trim() |> JSON.decode!()
  end
end
