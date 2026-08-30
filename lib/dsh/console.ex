defmodule DshBeam.Console do
  @moduledoc """
  The live web console — and the proof that the UI is a plugin like any
  other. This fiber owns the Phoenix endpoint: the endpoint starts when the
  console mounts, stops (synchronously) when it withdraws, and the LiveView
  reads the composition through the context/runtime subscription streams.

  The console also provides :console, so other plugins can declare a
  dependency on the UI as a capability.

  Entry config:

  - :server — start the HTTP listener (default false; the demo script sets
    true to serve on 127.0.0.1:4888)

  The listener port comes from config (`http: [port: 4888]`) and can be
  overridden at boot with the DSH_BEAM_PORT environment variable, so the
  console never collides with another dev server.
  """

  use DshBeam.Plugin

  @default_port 4888

  @doc "The effective console port: DSH_BEAM_PORT env var wins, else config."
  def port do
    configured =
      Application.get_env(:dsh_beam, DshBeamWeb.Endpoint, [])
      |> Keyword.get(:http, [])
      |> Keyword.get(:port, @default_port)

    case System.get_env("DSH_BEAM_PORT") do
      nil ->
        configured

      "" ->
        configured

      str ->
        case Integer.parse(str) do
          {p, ""} when p in 1..65_535 ->
            p

          _ ->
            raise ArgumentError, "invalid DSH_BEAM_PORT: #{inspect(str)} (want a port 1..65535)"
        end
    end
  end

  @impl DshBeam.Plugin
  def mount(ctx, opts) do
    runtime = Keyword.fetch!(opts, :runtime)
    server = Keyword.get(opts, :server, false)

    # Resolve the HTTP port: DSH_BEAM_PORT (if set) overrides the default
    # from config so the console cannot collide with another dev server.
    # The overlay is applied to the app env right before the endpoint
    # starts — Phoenix reads it at start_link time.
    endpoint_config =
      Application.get_env(:dsh_beam, DshBeamWeb.Endpoint, [])
      |> Keyword.put(:http, ip: {127, 0, 0, 1}, port: port())

    Application.put_env(:dsh_beam, DshBeamWeb.Endpoint, endpoint_config)

    # the web subtree (pubsub + endpoint) is started unlinked: the console
    # owns it explicitly and stops it synchronously in terminate/3. Phoenix
    # 1.8 no longer supervises the pubsub, hence the explicit start; its
    # supervisor takes the DshBeam.PubSub.Supervisor name while the registry
    # keeps DshBeam.PubSub (what the endpoint config points at). A console
    # re-injection adopts a subtree that is still tearing down instead of
    # failing the mount.
    # the web subtree (pubsub + endpoint) is started unlinked: the console
    # owns it explicitly and stops it synchronously in terminate/3. Phoenix
    # 1.8 no longer supervises the pubsub, hence the explicit start; its
    # supervisor takes the DshBeam.PubSub.Supervisor name while the registry
    # keeps DshBeam.PubSub (what the endpoint config points at). If a
    # previous console's subtree is still tearing down, wait for it instead
    # of adopting a dying process.
    pubsub =
      start_unlinked(fn ->
        Phoenix.PubSub.Supervisor.start_link(name: DshBeam.PubSub, adapter: Phoenix.PubSub.PG2)
      end)

    endpoint = start_unlinked(fn -> DshBeamWeb.Endpoint.start_link(server: server) end)

    # the fallback discovery channel for browser clients
    :persistent_term.put({DshBeam.Console, :refs}, %{runtime: runtime, ctx: ctx})

    {:ok, [], %{console: self()}, %{endpoint: endpoint, pubsub: pubsub}}
  end

  # Start an unlinked subtree, waiting out a previous instance that is still
  # shutting down (its name is still registered while it dies).
  #
  # A listen error (`:eaddrinuse`) is NOT retried: another console already
  # owns the port and will not die from a 500ms wait, so retrying would just
  # spam the log. We surface it once with a clear message instead of raising
  # the generic "web subtree start failed after retries".
  defp start_unlinked(start_fun, retries \\ 5)

  defp start_unlinked(_start_fun, 0) do
    raise "web subtree start failed after retries"
  end

  defp start_unlinked(start_fun, retries) do
    case start_fun.() do
      {:ok, pid} ->
        Process.unlink(pid)
        pid

      {:error, {:already_started, pid}} ->
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
        after
          500 -> :ok
        end

        start_unlinked(start_fun, retries - 1)

      {:error, {:listen_error, reason}} ->
        raise """
        failed to listen on 127.0.0.1:#{port()}: #{inspect(reason)}

        Another console is already serving this port. Either stop it first
        (./dsh-console.sh stop) or pick another port (DSH_BEAM_PORT=5000
        ./dsh-console.sh).
        """
    end
  end

  @impl true
  def terminate(reason, state, data) do
    :persistent_term.erase({DshBeam.Console, :refs})

    # stop the subtree defensively: either side may already be gone, and a
    # hung stop must not leak the other (both are unlinked)
    stop_sync(data.extra[:endpoint])
    stop_sync(data.extra[:pubsub])

    super(reason, state, data)
  end

  defp stop_sync(pid) do
    if is_pid(pid) and Process.alive?(pid) do
      Supervisor.stop(pid, :normal, 5000)
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end
end
