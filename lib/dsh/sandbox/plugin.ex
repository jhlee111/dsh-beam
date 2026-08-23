defmodule DshBeam.Sandbox.Plugin do
  @moduledoc """
  The host-side fiber of a sandboxed plugin — the guardian of the §6.3
  execution boundary.

  The untrusted source runs in a child OS process (its own BEAM, see
  priv/sandbox_runner.exs) connected through a Port. This fiber forwards the
  paper's lifecycle across the boundary:

  - mount/3 spawns the child, hands it the source, and waits for its
    declaration (deps + provides), which becomes this fiber's registration.
  - handle_dsh_activate/2 forwards the committed view; only inert data
    crosses — capabilities (pids, ports, refs, functions) are dropped.
  - handle_dsh_withdraw/2 forwards the withdrawal and waits for the child's
    teardown acknowledgement before the fiber acknowledges, so the binding
    outlives the sandboxed teardown.
  - When the child dies, the fiber stops with an abnormal reason: the
    runtime's re-injection machinery spawns a fresh child, while the
    context's monitor safety net withdraws this instance's bindings only
    after its dependents drained (ordered shutdown).

  Only keys that already exist as atoms on the host may cross the boundary
  (nominal capability keys): references to unknown keys fail loudly instead
  of creating atoms from untrusted input.
  """

  use DshBeam.Plugin

  require Logger

  @register_timeout 10_000
  @ack_timeout 1_000

  def view(pid), do: :gen_statem.call(pid, :view)
  def os_pid(pid), do: :gen_statem.call(pid, :os_pid)
  def kill_child(pid), do: :gen_statem.call(pid, :kill_child)

  @impl DshBeam.Plugin
  def mount(_ctx, opts) do
    source = Keyword.fetch!(opts, :source)
    config = Keyword.get(opts, :sandbox_config, %{})
    port = open_port(source, config)
    {deps, provides, buf} = await_register(port, "", @register_timeout)
    {:ok, deps, provides, %{port: port, buf: buf, provides: provides}}
  end

  @impl DshBeam.Plugin
  def handle_dsh_ready(state) do
    # a fiber that registers directly into :active never runs
    # handle_dsh_activate/2; forward the initial committed view so the
    # child's activation hook fires at startup too
    if Port.info(state.extra.port) != nil do
      send_line(state.extra.port, %{"activate" => sanitize(state.view)})
    end

    {:ok, state}
  end

  @impl DshBeam.Plugin
  def handle_dsh_activate(view, state) do
    if Port.info(state.extra.port) != nil do
      send_line(state.extra.port, %{"activate" => sanitize(view)})
    end

    {:ok, state}
  end

  @impl DshBeam.Plugin
  def handle_dsh_withdraw(keys, state) do
    if Port.info(state.extra.port) != nil do
      send_line(state.extra.port, %{"withdraw" => keys})
      await_ack(state.extra.port, "", @ack_timeout)
    end

    {:ok, state}
  end

  @impl DshBeam.Plugin
  def handle_dsh_info({port, {:data, chunk}}, state) when port == state.extra.port do
    {lines, rest} = split_lines(state.extra.buf <> chunk)
    state = Enum.reduce(lines, state, &handle_child_line/2)
    {:ok, %{state | extra: %{state.extra | buf: rest}}}
  end

  def handle_dsh_info({port, {:exit_status, status}}, state) when port == state.extra.port do
    # the child OS process died: ports do not emit an exit signal when their
    # external program dies, so the exit status is the crash detection. Treat
    # it as a plugin crash — the runtime re-injects a fresh child, the safety
    # net withdraws this instance after its dependents drained.
    {:stop, {:sandbox_crashed, status}, state}
  end

  def handle_dsh_info(_msg, state), do: {:ok, state}

  @impl DshBeam.Plugin
  def handle_dsh_exit(port, _reason, state) when port == state.extra.port do
    # our child's port closed: treat it as a plugin crash — the runtime
    # re-injects a fresh child, the safety net withdraws this instance after
    # its dependents drained
    {:stop, {:sandbox_crashed, port}, state}
  end

  def handle_dsh_exit(port, _reason, state) when is_port(port) do
    # a helper port closed (e.g. the one System.cmd opens internally): not
    # our boundary — ignore it
    {:ok, state}
  end

  def handle_dsh_exit(_from, _reason, state), do: {:stop, :normal, state}

  @impl true
  def terminate(reason, state, data) do
    port = data.extra.port

    # dependents drain first (super blocks on the context's unload
    # acknowledgement); only then does the child's own teardown run and the
    # boundary close — ordered shutdown extended across the boundary
    super(reason, state, data)

    if Port.info(port) != nil do
      send_line(port, %{"withdraw" => Map.keys(data.extra.provides)})
      await_ack(port, "", @ack_timeout)
      close_port(port)
    end

    :ok
  end

  @impl true
  def handle_event({:call, from}, :view, _state, data) do
    {:keep_state_and_data, [{:reply, from, data.view}]}
  end

  def handle_event({:call, from}, :os_pid, _state, data) do
    os_pid =
      case Port.info(data.extra.port) do
        nil -> nil
        info -> Keyword.get(info, :os_pid)
      end

    {:keep_state_and_data, [{:reply, from, os_pid}]}
  end

  def handle_event({:call, from}, :kill_child, _state, data) do
    result =
      case Port.info(data.extra.port) do
        nil ->
          :not_running

        info ->
          os_pid = Keyword.fetch!(info, :os_pid)

          # run the kill from an unlinked process: System.cmd opens a helper
          # port whose trailing exit signal must not reach this fiber
          Task.start(fn ->
            System.cmd("kill", ["-9", Integer.to_string(os_pid)], stderr_to_stdout: true)
          end)

          :ok
      end

    {:keep_state_and_data, [{:reply, from, result}]}
  end

  # -- boundary mechanics --

  defp open_port(source, config) do
    elixir = System.find_executable("elixir") || raise "elixir executable not found on PATH"
    runner = Path.join(:code.priv_dir(:dsh_beam), "sandbox_runner.exs")

    port = Port.open({:spawn_executable, elixir}, [:binary, :exit_status, args: [runner]])
    Port.command(port, JSON.encode!(%{"source" => source, "config" => config}) <> "\n")
    port
  end

  defp await_register(port, buf, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_register(port, buf, deadline)
  end

  defp do_await_register(port, buf, deadline) do
    timeout = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, chunk}} ->
        {lines, rest} = split_lines(buf <> chunk)

        case Enum.find(lines, &(JSON.decode(&1) != :error)) do
          nil ->
            do_await_register(port, rest, deadline)

          line ->
            case JSON.decode(line) do
              {:ok, %{"register" => %{"deps" => deps, "provides" => provides}}} ->
                {Enum.map(deps, &existing_key!/1),
                 Map.new(provides, fn {key, value} -> {existing_key!(key), value} end), rest}

              {:ok, %{"error" => message}} ->
                raise "sandbox child failed to start: #{message}"

              _ ->
                raise "unexpected sandbox protocol line: #{inspect(line)}"
            end
        end

      {:EXIT, ^port, _reason} ->
        raise "sandbox child exited before registering"
    after
      timeout ->
        raise "sandbox child timed out before registering"
    end
  end

  defp await_ack(port, buf, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_ack(port, buf, deadline)
  end

  defp do_await_ack(port, buf, deadline) do
    timeout = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, chunk}} ->
        {lines, rest} = split_lines(buf <> chunk)

        if Enum.any?(lines, fn line -> match?({:ok, %{"deactivated" => _}}, JSON.decode(line)) end) do
          :ok
        else
          do_await_ack(port, rest, deadline)
        end

      {:EXIT, ^port, _reason} ->
        :ok
    after
      timeout ->
        Logger.warning("sandbox child did not acknowledge withdrawal within #{@ack_timeout}ms")
        :ok
    end
  end

  defp handle_child_line(line, state) do
    case JSON.decode(line) do
      {:ok, %{"error" => message}} ->
        Logger.error("sandbox child reported an error: #{message}")
        state

      _ ->
        state
    end
  end

  defp send_line(port, msg), do: Port.command(port, JSON.encode!(msg) <> "\n")

  # the port may have closed between the Port.info check and the close
  # (its EXIT signal races the terminate path): a closed port is fine
  defp close_port(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp split_lines(buf) do
    {lines, [rest]} = Enum.split(String.split(buf, "\n"), -1)
    {lines, rest}
  end

  # Untrusted input must never create atoms on the host: only keys that
  # already exist (nominal capability keys) may cross the boundary.
  defp existing_key!(name) when is_binary(name) do
    try do
      String.to_existing_atom(name)
    rescue
      ArgumentError ->
        reraise "sandboxed plugin references key #{inspect(name)}, which does not exist on the host",
                __STACKTRACE__
    end
  end

  # Only inert data crosses the boundary: capabilities (pids, ports, refs,
  # functions) are dropped from the view sent to the child.
  defp sanitize(term) when is_map(term) do
    Map.new(term, fn {key, value} ->
      {key, if(json_leaf?(value), do: value, else: nil)}
    end)
  end

  defp sanitize(term) when is_list(term), do: Enum.filter(term, &json_leaf?/1)
  defp sanitize(term), do: term

  defp json_leaf?(value) do
    is_nil(value) or is_boolean(value) or is_number(value) or is_binary(value)
  end
end
