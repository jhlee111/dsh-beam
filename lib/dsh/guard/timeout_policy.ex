defmodule DshBeam.Guard.TimeoutPolicy do
  @moduledoc """
  Tool-call timeout enforcer — the harness's `guard/timeout-policy`.

  A tool declares a cooperative per-call budget (its `timeout_ms` in the tool
  DSL, or nil for no budget). When a call exceeds the budget, this guard
  returns a structured `TOOL_TIMEOUT` result instead of the tool's output, so
  a hung `bash`/`fetch` cannot stall the loop indefinitely.

  Cooperative, never a hard kill: the budget only bounds *this* call's wait —
  the tool process is not forcibly terminated, and a tool that ignores the
  deadline simply returns whatever it eventually produces. Budget is read from
  the tool's own declaration, so this guard is zero-config.

  `invoke/3` returns the model-facing result of a tool call under a deadline:
  `{:ok, output_string}` on success or timeout, `{:error, reason}` on a real
  tool error.
  """

  @doc """
  Invoke one tool call under a deadline. Returns `{:ok, String.t()}` (the
  model-facing output, or the TOOL_TIMEOUT message on a deadline win) or
  `{:error, reason}` for a tool error.
  """
  @spec invoke(pid(), atom(), map(), integer() | nil) :: {:ok, String.t()} | {:error, term()}
  def invoke(provider, name, args, timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0 do
    task = Task.async(fn -> DshBeam.Tool.call(provider, name, args) end)

    case Task.yield(task, timeout_ms) do
      {:ok, result} ->
        normalize(result)

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:ok, "error: tool call #{name} timed out after #{timeout_ms}ms"}
    end
  end

  def invoke(provider, name, args, _timeout_ms) do
    DshBeam.Tool.call(provider, name, args)
    |> normalize()
  end

  defp normalize({:ok, value}), do: {:ok, to_string(value)}
  defp normalize({:error, reason}), do: {:error, inspect(reason)}
end
