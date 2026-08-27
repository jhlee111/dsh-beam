defmodule DshBeam.Tool.Fs do
  @moduledoc """
  The fs tool: reads and writes files within a workspace root — a minimal
  slice of the harness's tool-fs. File writes are §6.1 "outside the boundary"
  effects; this PoC contains them to a declared root.

  The root is the current session's worktree when one is present (each session
  owns its checkout); otherwise it is the entry config `:root` (default the
  current directory). Paths that escape the root are refused.

  When `DshBeam.WorkspaceFolders` is mounted, its `:workspace_folders`
  binding extends the allowed roots with an explicit allowlist of extra
  folders (each with its own writable flag): reads resolve against every
  allowed root, writes are refused on a read-only extra folder, and anything
  outside the session root and the added folders is refused exactly as
  before. Without the plugin the behaviour is unchanged.
  """

  use DshBeam.Plugin

  need(:session)

  tool(:read_file,
    description: "Read a file within the workspace (or an added workspace folder)",
    parameters: %{
      "type" => "object",
      "properties" => %{"path" => %{"type" => "string"}},
      "required" => ["path"]
    }
  )

  tool(:write_file,
    description: "Write a file within the workspace (or an added writable workspace folder)",
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
    with {:ok, full} <- resolve_path(state, path, :read) do
      case File.read(full) do
        {:ok, content} -> {:ok, content}
        {:error, reason} -> {:error, inspect(reason)}
      end
    end
  end

  def handle_dsh_tool_call(:write_file, %{"path" => path, "content" => content}, state) do
    with {:ok, full} <- resolve_path(state, path, :write) do
      case File.write(full, content) do
        :ok -> {:ok, "wrote #{path}"}
        {:error, reason} -> {:error, inspect(reason)}
      end
    end
  end

  # Resolve a tool path against the session root, then against every added
  # workspace folder. Reads may target any allowed root; writes only roots
  # flagged writable (a read-only extra folder refuses writes, the session
  # root stays writable as before).
  defp resolve_path(state, path, mode) do
    root = workspace_root(state)

    cond do
      within?(full = Path.expand(path, root), root) ->
        {:ok, full}

      true ->
        case extra_folders(state) do
          [] ->
            {:error, :escapes_workspace}

          folders ->
            case allowed_extra(folders, Path.expand(path), mode) do
              {:ok, full} -> {:ok, full}
              {:error, reason} -> {:error, reason}
              :error -> {:error, :escapes_workspace}
            end
        end
    end
  end

  defp allowed_extra(folders, full, mode) do
    Enum.find_value(folders, :error, fn %{path: base, writable: writable} ->
      if within?(full, base) do
        if mode == :write and not writable do
          {:error, :readonly_folder}
        else
          {:ok, full}
        end
      end
    end)
  end

  defp within?(full, base), do: full == base or String.starts_with?(full, base <> "/")

  # The session's worktree is the workspace root; fall back to the entry config
  # :root when no session (or no session cwd) is present.
  defp workspace_root(state) do
    case session_cwd(state) do
      cwd when is_binary(cwd) -> cwd
      _ -> state.config |> Keyword.get(:root, ".") |> Path.expand()
    end
  end

  # The added folders, read from the :workspace_folders binding when the
  # WorkspaceFolders plugin is mounted and active; [] without it.
  defp extra_folders(state) do
    case DshBeam.Context.get(state.ctx, :workspace_folders) do
      {:ok, folders} when is_list(folders) -> folders
      _ -> []
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
