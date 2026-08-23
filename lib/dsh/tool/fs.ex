defmodule DshBeam.Tool.Fs do
  @moduledoc """
  The fs tool: reads and writes files within a workspace root — a minimal
  slice of the harness's tool-fs. File writes are §6.1 "outside the boundary"
  effects; this PoC contains them to a declared root.

  The root is the current session's worktree when one is present (each session
  owns its checkout); otherwise it is the entry config `:root` (default the
  current directory). Paths that escape the root are refused.
  """

  use DshBeam.Plugin

  need(:session)

  tool(:read_file,
    description: "Read a file within the workspace",
    parameters: %{
      "type" => "object",
      "properties" => %{"path" => %{"type" => "string"}},
      "required" => ["path"]
    }
  )

  tool(:write_file,
    description: "Write a file within the workspace",
    parameters: %{
      "type" => "object",
      "properties" => %{
        "path" => %{"type" => "string"},
        "content" => %{"type" => "string"}
      },
      "required" => ["path", "content"]
    }
  )

  @impl DshBeam.Plugin
  def handle_dsh_tool_call(:read_file, %{"path" => path}, state) do
    with {:ok, full} <- within_root(state, path) do
      case File.read(full) do
        {:ok, content} -> {:ok, content}
        {:error, reason} -> {:error, inspect(reason)}
      end
    end
  end

  def handle_dsh_tool_call(:write_file, %{"path" => path, "content" => content}, state) do
    with {:ok, full} <- within_root(state, path) do
      case File.write(full, content) do
        :ok -> {:ok, "wrote #{path}"}
        {:error, reason} -> {:error, inspect(reason)}
      end
    end
  end

  defp within_root(state, path) do
    root = workspace_root(state)
    full = Path.expand(path, root)

    if full == root or String.starts_with?(full, root <> "/") do
      {:ok, full}
    else
      {:error, :escapes_workspace}
    end
  end

  # The session's worktree is the workspace root; fall back to the entry config
  # :root when no session (or no session cwd) is present.
  defp workspace_root(state) do
    case session_cwd(state) do
      cwd when is_binary(cwd) -> cwd
      _ -> state.config |> Keyword.get(:root, ".") |> Path.expand()
    end
  end

  defp session_cwd(state) do
    case DshBeam.Context.resolve(state.ctx) do
      {:active, view} -> view_cwd(view)
      {:inactive, view} -> view_cwd(view)
      _ -> nil
    end
  end

  defp view_cwd(view) do
    case view[:session] do
      session when is_pid(session) -> DshBeam.Session.cwd(session)
      _ -> nil
    end
  end
end
