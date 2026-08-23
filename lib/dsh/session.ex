defmodule DshBeam.Session do
  @moduledoc """
  The session capability seam: an append-only event log — the single source
  of truth that model-visible facts and projections derive from.

  The Definition owns the call surface and the message protocol: every
  Provider is a GenServer answering {:append, event}, :all, and :count, so
  consumers dispatch through this module instead of importing a provider.
  """

  @typedoc "A session handle (a supervised provider process)."
  @type session :: pid()

  @typedoc "One appended event (lossless JSON in this PoC)."
  @type event :: term()

  @doc "Append one event; returns its sequence number."
  def append(session, event), do: GenServer.call(session, {:append, event})

  @doc "Read all events back in append order."
  def all(session), do: GenServer.call(session, :all)

  @doc "The number of appended events."
  def count(session), do: GenServer.call(session, :count)

  @doc "Truncate the log, dropping every event (a fresh conversation)."
  def clear(session), do: GenServer.call(session, :clear)

  @doc "The session header (title/cwd) — its identity and working directory."
  def header(session), do: GenServer.call(session, :header)

  @doc "The session's working directory (its header cwd), or nil when unset/dead."
  def cwd(session) when is_pid(session) do
    try do
      if Process.alive?(session) do
        case header(session) do
          %{cwd: cwd} when is_binary(cwd) -> cwd
          _ -> nil
        end
      end
    catch
      :exit, _ -> nil
    end
  end

  @doc "Merge a map into the session header (e.g. set its cwd)."
  def set_header(session, header) when is_map(header),
    do: GenServer.call(session, {:set_header, header})

  @doc """
  Subscribe the calling process to session appends. Each append fans out
  {:dsh_session_event, event} to every subscriber; the subscription is removed
  when the subscriber dies. This is the session as a reactive coeffect: an
  observer re-renders as the conversation grows, instead of polling.
  """
  def subscribe(session), do: GenServer.call(session, :subscribe)
end
