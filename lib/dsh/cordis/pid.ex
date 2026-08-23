defmodule DshBeam.Pid do
  @moduledoc """
  Pid utilities that behave across :erlang.dist: Process.alive?/1 raises for a
  remote pid, so aliveness checks that may see a remote owner delegate here —
  remote pids are assumed alive (send/2 to them is a safe no-op when dead,
  and protected calls are covered by their own exit handling).
  """

  @doc "Whether a local or remote pid may be alive. Remote pids read as true."
  def alive?(pid) when is_pid(pid) do
    node(pid) != node() or Process.alive?(pid)
  end
end
