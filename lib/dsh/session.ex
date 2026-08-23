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
end
