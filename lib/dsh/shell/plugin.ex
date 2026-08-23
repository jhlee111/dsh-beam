defmodule DshBeam.Shell.Plugin do
  @moduledoc """
  The shell capability provider — a non-LLM example of "everything is a
  plugin": runs commands in a subprocess with typed limits (the original
  harness's Shell settings: command timeout, output cap per stream).

  run/3 returns:

  - {:ok, output} — exit status 0
  - {:error, {:exit_status, status}, output} — a non-zero exit
  - {:error, :timeout, ""} — the command exceeded :command_timeout_ms
  """

  use DshBeam.Plugin

  setting(:command_timeout_ms,
    type: :integer,
    default: 60_000,
    doc: "How long one command may run before it is terminated"
  )

  setting(:output_cap_bytes,
    type: :integer,
    default: 64_000,
    doc: "Output cap per stream (bytes); beyond this the output is truncated"
  )

  def run(shell, command, args \\ []) when is_pid(shell) do
    :gen_statem.call(shell, {:run, command, args})
  end

  @doc """
  Run a command in a specific working directory (the session's worktree).
  Each session owns its own `cwd`, so two sessions over one repository do not
  clobber each other's files.
  """
  def run_in(shell, cwd, command, args \\ []) when is_pid(shell) and is_binary(cwd) do
    :gen_statem.call(shell, {:run_in, cwd, command, args})
  end

  @impl DshBeam.Plugin
  def mount(_ctx, opts) do
    timeout = Keyword.get(opts, :command_timeout_ms, 60_000)
    cap = Keyword.get(opts, :output_cap_bytes, 64_000)
    {:ok, [], %{shell: self()}, %{timeout: timeout, cap: cap}}
  end

  @impl true
  def handle_event({:call, from}, {:run, command, args}, _state, data) do
    result = run_command(command, args, nil, data.extra)
    {:keep_state_and_data, [{:reply, from, result}]}
  end

  def handle_event({:call, from}, {:run_in, cwd, command, args}, _state, data) do
    result = run_command(command, args, cwd, data.extra)
    {:keep_state_and_data, [{:reply, from, result}]}
  end

  defp run_command(command, args, cwd, extra) do
    # System.cmd has no timeout and its subprocess port must not link to the
    # fiber (a linked completion EXIT would stop the fiber). Run it in an
    # unlinked, monitored process and have it send the result back.
    parent = self()
    command = to_string(command)
    args = Enum.map(args, &to_string/1)
    opts = if cwd, do: [stderr_to_stdout: true, cd: cwd], else: [stderr_to_stdout: true]

    pid =
      spawn(fn ->
        send(parent, {:shell_result, self(), System.cmd(command, args, opts)})
      end)

    ref = Process.monitor(pid)

    receive do
      {:shell_result, ^pid, result} ->
        Process.demonitor(ref, [:flush])
        finish(result, extra.cap)

      {:DOWN, ^ref, :process, ^pid, _reason} ->
        {:error, :crashed, ""}
    after
      extra.timeout ->
        Process.exit(pid, :kill)
        Process.demonitor(ref, [:flush])
        {:error, :timeout, ""}
    end
  end

  defp finish({output, 0}, cap), do: {:ok, cap_output(output, cap)}

  defp finish({output, status}, cap),
    do: {:error, {:exit_status, status}, cap_output(output, cap)}

  defp cap_output(output, cap) when byte_size(output) <= cap, do: output
  defp cap_output(output, cap), do: binary_part(output, 0, cap)
end
