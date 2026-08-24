defmodule DshBeam.Agent.Cancel do
  @moduledoc """
  A cooperative cancellation token for one agent turn — the OTP analogue of
  the reference's `AbortController`/`AbortSignal`.

  The token is a single-slot `:atomics` cell, so it is lock-free and needs no
  process: the caller mints one per turn, the agent loop polls `cancelled?/1`
  at its step boundaries, and a UI `stop` flips it with `cancel/1` from any
  process. Polling a token that was never minted (or already collected) is
  treated as *not cancelled*, so legacy `run/2`/`run_trace/2` callers keep
  working unchanged.
  """

  @opaque t :: :atomics.atomics_ref()

  @typedoc "A minted cancellation token."
  @type token :: t()

  @doc "Mint a fresh, non-cancelled token for one turn."
  @spec new() :: token()
  def new do
    :atomics.new(1, signed: false)
  end

  @doc "Signal cancellation. Idempotent and safe from any process."
  @spec cancel(token()) :: :ok
  def cancel(token) do
    :atomics.put(token, 1, 1)
    :ok
  end

  @doc "Whether this token has been cancelled."
  @spec cancelled?(token()) :: boolean()
  def cancelled?(token) do
    :atomics.get(token, 1) == 1
  rescue
    # A collected token (or a non-token term passed defensively) is not live
    # and therefore not cancelled.
    ArgumentError -> false
  catch
    :error, _ -> false
  end
end
