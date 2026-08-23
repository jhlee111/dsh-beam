defmodule DshBeam.Shell.Consumer do
  @moduledoc """
  A shell consumer: declares :shell and runs one configured command on
  demand — the minimal dependent demonstrating the L-Unload guard across a
  non-LLM capability (removing :shell deactivates this fiber first).
  """

  use DshBeam.Plugin

  def run(pid) when is_pid(pid), do: :gen_statem.call(pid, :run)

  @impl DshBeam.Plugin
  def mount(_ctx, opts) do
    command = Keyword.fetch!(opts, :command)
    args = Keyword.get(opts, :args, [])
    {:ok, [:shell], %{}, %{command: command, args: args, parent: Keyword.get(opts, :parent)}}
  end

  @impl DshBeam.Plugin
  def handle_dsh_ready(state) do
    if state.extra.parent, do: send(state.extra.parent, {:shell_consumer_active, self()})
    {:ok, state}
  end

  @impl true
  def handle_event({:call, from}, :run, _state, data) do
    result =
      DshBeam.Shell.Plugin.run(Map.fetch!(data.view, :shell), data.extra.command, data.extra.args)

    {:keep_state_and_data, [{:reply, from, result}]}
  end
end
