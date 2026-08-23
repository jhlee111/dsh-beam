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

  @impl DshBeam.Plugin
  def mount(_ctx, opts) do
    timeout = Keyword.get(opts, :command_timeout_ms, 60_000)
    cap = Keyword.get(opts, :output_cap_bytes, 64_000)
    {:ok, [], %{shell: self()}, %{timeout: timeout, cap: cap}}
  end

  @impl true
  def handle_event({:call, from}, {:run, command, args}, _state, data) do
    result = run_command(command, args, data.extra)
    {:keep_state_and_data, [{:reply, from, result}]}
  end

  defp run_command(command, args, extra) do
    # System.cmd has no timeout: run it in a linked task and kill the task
    # (which owns the subprocess port) when it overruns.
    task =
      Task.async(fn ->
        System.cmd(to_string(command), Enum.map(args, &to_string/1), stderr_to_stdout: true)
      end)

    case Task.yield(task, extra.timeout) do
      {:ok, {output, 0}} ->
        {:ok, cap(output, extra.cap)}

      {:ok, {output, status}} ->
        {:error, {:exit_status, status}, cap(output, extra.cap)}

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, :timeout, ""}
    end
  end

  defp cap(output, cap) when byte_size(output) <= cap, do: output
  defp cap(output, cap), do: binary_part(output, 0, cap)
end
