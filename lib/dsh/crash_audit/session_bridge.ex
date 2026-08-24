defmodule DshBeam.CrashAudit.SessionBridge do
  @moduledoc """
  Interleaves crash audit events into the session log, so "what died and why"
  is visible inside the conversation itself — not only in `.dsh/crash-audit.log`.

  The bridge depends on `:session` and `:crash_audit`. On activation it
  subscribes to the live audit stream and drains any events that happened
  before it was active (e.g. a plugin that crash-looped during boot). Each
  event becomes one `%{"role" => "crash_audit", ...}` row in the session —
  the same append-only log the chat and trajectory projections read, so the
  crash shows up as a normal row in the UI.

  ## Deduplication

  `append_unless_present/2` skips an event whose `{timestamp, kind, id}`
  already exists in the session. That makes the bridge idempotent across
  activations and runtime restarts: a file-backed workspace session keeps the
  row, and a restarted bridge re-draining the retained audit window cannot
  append it twice.

  The bridge subscribes/unsubscribes as a fiber: when either dependency is
  withdrawn it unsubscribes, and the next activation drains + re-subscribes.
  """

  use DshBeam.Plugin

  @impl DshBeam.Plugin
  def mount(_ctx, _opts) do
    {:ok, [:session, :crash_audit], %{}, %{}}
  end

  # A fiber that starts with every dependency already present goes straight
  # to :active and only sees handle_dsh_ready/1 (not the activate message), so
  # both entry points must ensure the subscription + drain.
  @impl true
  def handle_dsh_ready(state) do
    ensure_interleaved(state.view)
    {:ok, state}
  end

  @impl true
  def handle_dsh_activate(view, state) do
    ensure_interleaved(view)
    {:ok, state}
  end

  defp ensure_interleaved(%{crash_audit: audit, session: session})
       when is_pid(audit) and is_pid(session) do
    # subscribe first (idempotent), then drain: events recorded between the
    # two calls are delivered live and deduped by append_unless_present
    :ok = DshBeam.CrashAudit.subscribe(audit)

    audit
    |> DshBeam.CrashAudit.all()
    |> Enum.reverse()
    |> Enum.each(&append_unless_present(session, &1))

    :ok
  end

  defp ensure_interleaved(_view), do: :ok

  @impl true
  def handle_dsh_withdraw(keys, state) do
    if :crash_audit in keys do
      case state.view do
        %{crash_audit: audit} -> DshBeam.CrashAudit.unsubscribe(audit)
        _ -> :ok
      end
    end

    {:ok, state}
  end

  @impl true
  def handle_dsh_info({:crash_audit, event}, state) do
    case state.view do
      %{session: session} -> append_unless_present(session, event)
      _ -> :ok
    end

    {:ok, state}
  end

  def handle_dsh_info(_msg, state), do: {:ok, state}

  # -- append, deduped against the session content --

  defp append_unless_present(session, %DshBeam.CrashAudit.Event{} = event) do
    # the dedup key uses the SAME stringified forms the session row stores
    # (JSONL: kind and id are binaries), so a re-drained event never dupes
    key = {event.timestamp, Atom.to_string(event.kind), inspect(event.id)}

    already? =
      DshBeam.Session.all(session)
      |> Enum.any?(fn row ->
        match?(
          %{
            "role" => "crash_audit",
            "timestamp" => ts,
            "kind" => kind,
            "id" => id
          }
          when {ts, kind, id} == key,
          row
        )
      end)

    unless already?, do: DshBeam.Session.append(session, to_session_event(event))

    :ok
  end

  # The session log is JSONL (Session.File JSON-encodes every append), so the
  # row must be a flat map with binary keys and scalar values.
  defp to_session_event(%DshBeam.CrashAudit.Event{} = event) do
    %{
      "role" => "crash_audit",
      "timestamp" => event.timestamp,
      "kind" => Atom.to_string(event.kind),
      "id" => inspect(event.id),
      "reason" => event.reason
    }
  end
end
