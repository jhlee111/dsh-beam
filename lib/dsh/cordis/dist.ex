defmodule DshBeam.Dist do
  @moduledoc """
  §6.2 cross-node composition: a fiber can live on another BEAM node and
  register with a context elsewhere. The context's monitor, activation
  messages, and the L-Unload guard all cross :erlang.dist — a remote owner is
  just a {pid, node}.

  start_provider/2 runs on the remote node (via :rpc): it spawns an unlinked
  keep-alive process that starts a provider fiber registering with the given
  context, and returns the fiber pid.
  """

  @doc "Start a provider fiber on the calling (remote) node, registering with ctx."
  def start_provider(ctx, provides) when is_pid(ctx) and is_map(provides) do
    caller = self()
    ref = make_ref()

    spawn(fn ->
      {:ok, pid} = DshBeam.Provider.start_link(ctx, id: {:remote, node()}, provides: provides)
      send(caller, {ref, pid})
      Process.sleep(:infinity)
    end)

    receive do
      {^ref, pid} -> pid
    after
      10_000 -> exit(:remote_fiber_timeout)
    end
  end
end
