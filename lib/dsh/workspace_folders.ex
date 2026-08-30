defmodule DshBeam.WorkspaceFolders do
  @moduledoc """
  Extra workspace folders — the "a few more folders, not the whole disk"
  capability.

  The session workspace is a single root (the session's worktree, owned by
  `DshBeam.Workspace`). For repos/reference material the agent must also
  read — and sometimes write — across several related folders, this plugin
  adds an explicit allowlist of extra absolute paths. Every added folder is
  opt-in (never a wildcard), each carries its own `writable` flag, and the
  list is persisted to the typed settings store (`extra_folders`, one
  `w /abs/path` or `r /abs/path` per line), so it survives a restart.

  The plugin provides `:workspace_folders` — a list of
  `%{path: String.t(), writable: boolean()}` — which `DshBeam.Tool.Fs`
  consults at call time: reads resolve against every allowed root, writes are
  refused on a `read-only` folder, and anything outside the session root and
  the added folders is refused exactly as before (no plugin configured means
  behaviour is unchanged).
  """

  use DshBeam.Plugin

  setting(:extra_folders,
    type: :string,
    default: "",
    doc: "Extra folders the agent may access (one `w /abs/path` or `r /abs/path` per line)"
  )

  tool(:workspace_folders,
    description:
      "List the extra folders the agent may read/write outside the session workspace (absolute paths + writable flag)",
    parameters: %{"type" => "object", "properties" => %{}}
  )

  @doc "Parse the setting string into folder structs: %{path, writable}."
  def parse_folders(str) when is_binary(str) do
    str
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&parse_line/1)
    |> Enum.uniq_by(& &1.path)
  end

  def parse_folders(_), do: []

  defp parse_line("w " <> path), do: %{path: Path.expand(String.trim(path)), writable: true}
  defp parse_line("r " <> path), do: %{path: Path.expand(String.trim(path)), writable: false}

  defp parse_line(path) do
    # a bare path (e.g. typed by hand in the settings field) defaults to
    # writable, matching the "add a folder to work in it" intent
    %{path: Path.expand(String.trim(path)), writable: true}
  end

  @doc "Encode folder structs back to the setting string (one `w|r path` per line)."
  def encode_folders(folders) when is_list(folders) do
    folders
    |> Enum.map(fn %{path: path, writable: writable} ->
      prefix = if writable, do: "w", else: "r"
      "#{prefix} #{path}"
    end)
    |> Enum.join("\n")
  end

  @impl DshBeam.Plugin
  def mount(_ctx, opts) do
    folders = opts |> Keyword.get(:extra_folders, "") |> parse_folders()
    {:ok, [], %{workspace_folders: folders}, %{folders: folders}}
  end

  @impl true
  def handle_dsh_tool_call(:workspace_folders, _args, state) do
    {:ok, inspect(state.extra.folders)}
  end
end
