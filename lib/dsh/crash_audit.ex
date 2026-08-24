defmodule DshBeam.CrashAudit do
  @moduledoc """
  The crash audit log: a durable, append-only record of every plugin failure
  the orchestrator observes, so a crash is never only in memory (the runtime
  entry record is overwritten on the next re-injection) and "what died and
  why" survives a console restart.

  The audit is intentionally tiny and side-effect-only: it appends one JSONL
  line per failure (same encoding the session log uses) and fans the event
  out to live subscribers. It performs no supervision itself — the
  orchestrator (DshBeam.Runtime) stays the single owner of the lifecycle and
  calls `record/3` from its `:DOWN` and start-failure paths.

  ## Storage

  `record/3` writes to the file given in `start_link(opts)` (default
  `./.dsh/crash-audit.log`), so a console crash trail lives next to the
  persisted settings store and is gitignored with the rest of `.dsh/`.

  ## Subscribe

  `subscribe/1` registers the caller for `{:crash_audit, event}` messages;
  the subscription dies with the subscriber. This is how a console panel or
  the session log can surface crashes without polling the file.
  """

  use GenServer

  alias DshBeam.CrashAudit.Event

  @doc "Default audit path, relative to the caller's working directory."
  def default_path do
    Path.join([File.cwd!(), ".dsh", "crash-audit.log"])
  end

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Append a crash event and notify subscribers. `kind` is a short atom
  (`:crashed`, `:crash_loop`, `:start_failed`, `:exited`), `id` the plugin
  entry id, `reason` the exit/start reason. Returns `:ok` even when the
  write fails (the audit must never take the orchestrator down).
  """
  def record(audit, kind, id, reason) do
    GenServer.cast(audit, {:record, kind, id, reason})
  end

  @doc "The events currently held in memory (bounded to the latest 200)."
  def all(audit) do
    GenServer.call(audit, :all)
  end

  @doc """
  Subscribe the caller to live crash events: every record/3 becomes
  `{:crash_audit, %DshBeam.CrashAudit.Event{}}`. The subscription is removed
  when the subscriber dies.
  """
  def subscribe(audit) do
    GenServer.call(audit, :subscribe)
  end

  @doc "Unsubscribe the caller: stop receiving {:crash_audit, event} messages."
  def unsubscribe(audit) do
    GenServer.call(audit, :unsubscribe)
  end

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :path) || default_path()

    if path do
      File.mkdir_p!(Path.dirname(path))
    end

    {:ok,
     %{
       path: path,
       events: [],
       retained: Keyword.get(opts, :max_retained, 200),
       subscribers: %{}
     }}
  end

  @impl true
  def handle_cast({:record, kind, id, reason}, state) do
    event = Event.new(kind, id, reason)

    write_line(state.path, event)
    notify(state.subscribers, event)

    {:noreply, push_retained(state, event)}
  end

  @impl true
  def handle_call(:all, _from, state) do
    {:reply, state.events, state}
  end

  def handle_call(:subscribe, {owner, _tag}, state) do
    case state.subscribers do
      %{^owner => _ref} ->
        {:reply, :ok, state}

      _ ->
        ref = Process.monitor(owner)
        {:reply, :ok, %{state | subscribers: Map.put(state.subscribers, owner, ref)}}
    end
  end

  def handle_call(:unsubscribe, {owner, _tag}, state) do
    case Map.pop(state.subscribers, owner) do
      {nil, subscribers} ->
        {:reply, :ok, %{state | subscribers: subscribers}}

      {ref, subscribers} ->
        Process.demonitor(ref, [:flush])
        {:reply, :ok, %{state | subscribers: subscribers}}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | subscribers: Map.delete(state.subscribers, pid)}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp push_retained(%{events: events, retained: retained} = state, event) do
    # newest first, bounded: the durable record is the file, this is only a
    # live window for the UI / tests
    %{state | events: [event | events] |> Enum.take(retained)}
  end

  defp write_line(nil, _event), do: :ok

  defp write_line(path, event) do
    File.open(path, [:append], fn io ->
      IO.puts(io, JSON.encode!(encode_event(event)))
    end)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # The JSON encoder (Elixir's builtin) accepts maps with binary keys and
  # plain scalars only: an audit line is a flat map, ids/atoms are
  # stringified (inspect keeps tuples readable).
  defp encode_event(event) do
    %{
      "timestamp" => event.timestamp,
      "kind" => Atom.to_string(event.kind),
      "id" => inspect(event.id),
      "reason" => event.reason
    }
  end

  defp notify(subscribers, event) do
    Enum.each(subscribers, fn {pid, _ref} ->
      send(pid, {:crash_audit, event})
    end)
  end
end

defmodule DshBeam.CrashAudit.Event do
  @moduledoc """
  One crash audit record. `timestamp` is the system time in milliseconds,
  `kind` one of `:crashed` | `:crash_loop` | `:start_failed` | `:exited`,
  `id` the plugin entry id, and `reason` the exit/start reason (kept
  printable for JSON encoding).
  """

  @enforce_keys [:timestamp, :kind, :id]
  defstruct [:timestamp, :kind, :id, :reason]

  @type t :: %__MODULE__{
          timestamp: non_neg_integer(),
          kind: atom(),
          id: term(),
          reason: term()
        }

  def new(kind, id, reason) do
    %__MODULE__{
      timestamp: System.system_time(:millisecond),
      kind: kind,
      id: id,
      reason: printable_reason(reason)
    }
  end

  @doc "Coerce a reason to a JSON-safe printable term (atoms stay atoms for `inspect`-style logs)."
  def printable_reason(reason) when is_atom(reason) or is_binary(reason) or is_number(reason),
    do: reason

  def printable_reason(reason), do: inspect(reason)
end
