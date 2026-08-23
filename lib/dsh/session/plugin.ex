defmodule DshBeam.Session.Plugin do
  @moduledoc """
  The first plugin of the harness: provides the session log under :session.

  The provider implementation is configurable (:provider), so swapping Memory
  and File is a plain configuration change (a provider swap).

  The session server is started unlinked: its lifetime is governed by the
  withdrawal protocol, not by this plugin's process. A release inverse
  registered with the context stops it — after dependents drained, on both
  the graceful and the crash path (ordered shutdown).
  """

  use DshBeam.Plugin

  def session(pid), do: :gen_statem.call(pid, :session)

  @impl DshBeam.Plugin
  def mount(_ctx, opts) do
    provider = Keyword.get(opts, :provider, DshBeam.Session.Memory)
    {:ok, session} = provider.start(opts)
    {:ok, [], %{session: session}, %{session: session}}
  end

  @impl DshBeam.Plugin
  def handle_dsh_ready(state) do
    session = state.extra.session

    :ok =
      DshBeam.Context.effect(state.ctx, fn st ->
        if Process.alive?(session), do: Process.exit(session, :shutdown)
        st
      end)

    {:ok, state}
  end

  @impl true
  def handle_event({:call, from}, :session, _state, data) do
    {:keep_state_and_data, [{:reply, from, data.extra.session}]}
  end

  @impl true
  def terminate(reason, state, data) do
    super(reason, state, data)

    # fallback for whole-application shutdown, when the context may already
    # be gone and the release inverse never ran
    session = data.extra.session
    if Process.alive?(session), do: Process.exit(session, :shutdown)

    :ok
  end
end
