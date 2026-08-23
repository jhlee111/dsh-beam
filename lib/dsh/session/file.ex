defmodule Dsh.Session.File do
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

    {:ok, %{path: path, seq: length(events)}}
  end

  @impl true
  def handle_call({:append, event}, _from, state) do
    seq = state.seq + 1
    File.open(state.path, [:append], fn io -> IO.puts(io, JSON.encode!(event)) end)
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

  defp decode_line(line) do
    line |> String.trim() |> JSON.decode!()
  end
end
