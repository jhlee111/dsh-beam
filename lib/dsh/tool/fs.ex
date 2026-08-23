defmodule DshBeam.Tool.Fs do
  @moduledoc """
  The fs tool: reads and writes files within a workspace root — a minimal
  slice of the harness's tool-fs. File writes are §6.1 "outside the boundary"
  effects; this PoC contains them to a declared root.

  Entry config: :root — the workspace directory (default the current dir).
  """

  use DshBeam.Plugin

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
    root = state.config |> Keyword.get(:root, ".") |> Path.expand()
    full = Path.expand(path, root)

    if full == root or String.starts_with?(full, root <> "/") do
      {:ok, full}
    else
      {:error, :escapes_workspace}
    end
  end
end
