defmodule DshBeam.Tool.Bash do
  @moduledoc """
  The bash tool: a plugin that needs :shell and exposes the :bash tool — the
  harness's tool-bash. A tool is a plugin; removing :shell deactivates this
  tool first (the L-Unload guard).
  """

  use DshBeam.Plugin

  need(:shell)

  tool(:bash,
    description: "Run a shell command and return its output",
    parameters: %{
      "type" => "object",
      "properties" => %{"command" => %{"type" => "string", "description" => "the command line"}},
      "required" => ["command"]
    }
  )

  @impl DshBeam.Plugin
  def handle_dsh_tool_call(:bash, %{"command" => command}, state) do
    case DshBeam.Context.resolve(state.ctx) do
      {:active, %{shell: shell}} ->
        case DshBeam.Shell.Plugin.run(shell, "sh", ["-c", command]) do
          {:ok, output} -> {:ok, output}
          {:error, reason, output} -> {:error, %{reason: reason, output: output}}
        end

      _ ->
        {:error, :shell_unavailable}
    end
  end
end
