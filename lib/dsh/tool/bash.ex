defmodule DshBeam.Tool.Bash do
  @moduledoc """
  The bash tool: a plugin that needs :shell and :session and exposes the :bash
  tool — the harness's tool-bash. A tool is a plugin; removing :shell or
  :session deactivates this tool first (the L-Unload guard).

  Commands run in the current session's working directory (its worktree), so
  two sessions over one repository never clobber each other's files.
  """

  use DshBeam.Plugin

  need(:shell)
  need(:session)

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
      {:active, view} -> run(view, command)
      {:inactive, view} -> run(view, command)
      _ -> {:error, :shell_unavailable}
    end
  end

  defp run(view, command) do
    case view[:shell] do
      nil ->
        {:error, :shell_unavailable}

      shell ->
        result = run_command(shell, view[:session], command)

        case result do
          {:ok, output} -> {:ok, output}
          {:error, reason, output} -> {:error, %{reason: reason, output: output}}
        end
    end
  end

  # The session's worktree is the working directory; without one, fall back to
  # the shell's own cwd.
  defp run_command(shell, session, command) do
    case session_cwd(session) do
      cwd when is_binary(cwd) -> DshBeam.Shell.Plugin.run_in(shell, cwd, "sh", ["-c", command])
      _ -> DshBeam.Shell.Plugin.run(shell, "sh", ["-c", command])
    end
  end

  defp session_cwd(session) when is_pid(session), do: DshBeam.Session.cwd(session)
  defp session_cwd(_), do: nil
end
