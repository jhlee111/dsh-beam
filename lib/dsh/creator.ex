defmodule DshBeam.Creator do
  @moduledoc """
  Creator mode: compile plugin source at runtime, mount it as a supervised
  fiber, and swap or withdraw it.

  - define/2 compiles, loads through the BEAM code server, and mounts. The
    module registry makes introducing and retracting code first-class (paper
    §6.4 — Node's ES module registry cannot evict; BEAM can).
  - redefine/2 is the paper's transactional hot module replacement (§5.2.2):
    the new source compiles first (a syntax error changes nothing), the old
    fiber withdraws through the guard, the code swaps, the new fiber mounts,
    and a failed start rolls back to the old code and fiber.
  - undefine/2 withdraws the fiber and unloads the code.

  Creator-supplied source is trusted in this PoC: module names become atoms
  and code runs in-process. Untrusted creators go through DshBeam.Sandbox,
  the paper's §6.3 execution boundary (a child OS process with its own BEAM).
  """

  @doc """
  Compile source, load it, and mount it as one plugin entry. Transactional:
  a failed mount rolls the composition back to its pre-define state, so a
  broken plugin never lingers in the desired configuration.

  Returns {:ok, module} or {:error, {:compile, _}} | {:error, {:mount, _}}.
  """
  def define(runtime, source, opts \\ []) do
    with {:ok, mod, binary} <- compile(source),
         {:module, ^mod} <- load(mod, binary) do
      mount(runtime, mod, Keyword.get(opts, :config, []))
    end
  end

  @doc """
  Transactional hot replacement of the plugin defined by source (same
  module name as the currently mounted one). See the moduledoc for the
  failure semantics.
  """
  def redefine(runtime, source, opts \\ []) do
    with {:ok, mod, binary} <- compile(source),
         {:ok, old_binary} <- old_code(mod) do
      entries = current_entries(runtime)

      # 1. withdraw the old fiber (its dependents drain through the guard)
      :ok = DshBeam.Runtime.reconcile(runtime, Enum.reject(entries, &(&1.id == mod)))

      # 2. swap the code
      purge_and_delete(mod)
      load(mod, binary)

      # 3. start the new fiber; roll back on failure
      case mount(runtime, mod, Keyword.get(opts, :config, [])) do
        {:ok, mod} ->
          {:ok, mod}

        {:error, reason} ->
          restore_code(mod, old_binary)
          DshBeam.Runtime.reconcile(runtime, entries)
          {:error, {:start_failed, reason}}
      end
    end
  end

  @doc "Withdraw the plugin fiber and unload its code."
  def undefine(runtime, mod) do
    entries = current_entries(runtime)
    :ok = DshBeam.Runtime.reconcile(runtime, Enum.reject(entries, &(&1.id == mod)))
    purge_and_delete(mod)
    :ok
  end

  @doc """
  Export the live composition and its creator-defined plugin sources as a
  deployable plugin file — a standalone `.exs` script that (re)compiles the
  runtime-defined plugin source and re-mounts the whole composition, so an
  edited plugin survives a restart and can be shared.

  `export_plugin(runtime, path, sources)` writes a script that, when run with
  `mix run`, boots a runtime with every current entry plus the given source
  strings (creator-defined plugins are recompiled from source, not a binary).
  Returns `{:ok, path}`.
  """
  def export_plugin(runtime, path, sources \\ %{}) when is_map(sources) do
    entries = current_entries(runtime)
    content = plugin_script(entries, sources)

    case File.write(path, content) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Load an exported plugin script by evaluating it. Returns `{:ok, runtime}` on
  success, `{:error, :not_found}` when the file does not exist.
  """
  def import_plugin(path) do
    if File.exists?(path) do
      {result, _binding} = Code.eval_file(path)
      {:ok, result}
    else
      {:error, :not_found}
    end
  end

  @doc """
  The global plugin directory — a per-user store of saved plugin sources that
  any workspace/project can load (the "save as an actual plugin" option).
  """
  def plugins_dir do
    Path.join([System.user_home!(), ".dsh", "plugins"])
  end

  @doc """
  Save a plugin's source as a reusable `.exs` file under `dir` (default
  `plugins_dir/0`). `name` is sanitized to a filename; returns `{:ok, path}`.
  """
  def save_plugin(name, source, dir \\ plugins_dir())
      when is_binary(name) and is_binary(source) and is_binary(dir) do
    File.mkdir_p!(dir)

    filename =
      name |> String.trim() |> String.replace(~r/[^a-zA-Z0-9_-]+/, "-") |> String.trim("-")

    path = Path.join(dir, "#{filename}.exs")

    case File.write(path, source) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Load every saved plugin (each `.exs` under `dir`, default `plugins_dir/0`)
  and mount it into the runtime. Returns the list of per-file results
  (`{:ok, module}` or an error), so a broken saved plugin is reported, not
  silent.
  """
  def load_saved_plugins(runtime, dir \\ plugins_dir()) do
    dir
    |> saved_plugin_paths()
    |> Enum.map(fn path ->
      source = File.read!(path)
      define(runtime, source)
    end)
  end

  defp saved_plugin_paths(dir) do
    dir
    |> Path.join("*.exs")
    |> Path.wildcard()
    |> Enum.sort()
  end

  defp plugin_script(entries, sources) do
    source_blocks =
      sources
      |> Enum.map(fn {_mod, src} -> src end)
      |> Enum.join("\n\n")

    entries_code =
      entries
      |> Enum.map(fn entry ->
        "%{id: #{inspect(entry.id)}, plugin: #{inspect(entry.plugin)}, config: #{inspect(entry.config)}, disabled: #{inspect(entry.disabled)}}"
      end)
      |> Enum.join(",\n    ")

    """
    # dsh-beam plugin export — generated by DshBeam.Creator.export_plugin/3
    # Run with:  mix run <this-file>
    # Re-mounts the full composition, recompiling creator-defined plugins from source.

    #{source_blocks}

    entries = [
      #{entries_code}
    ]

    {:ok, runtime} = DshBeam.Runtime.start_link(entries, [])
    runtime
    """
  end

  defp compile(source) do
    with {:ok, mod} <- module_name(source) do
      results =
        try do
          Code.compile_string(source)
        rescue
          # malformed source raises instead of returning diagnostics
          e in [SyntaxError, TokenMissingError] -> {:error, e}
        end

      case results do
        {:error, reason} ->
          {:error, {:compile, reason}}

        results when is_list(results) ->
          case Enum.find(results, fn {m, binary} -> m == mod and is_binary(binary) end) do
            {^mod, binary} -> {:ok, mod, binary}
            nil -> {:error, {:compile, results}}
          end
      end
    end
  end

  defp module_name(source) do
    case Regex.run(~r/^\s*defmodule\s+([A-Z]\w*)/, source) do
      # Module.concat builds the Elixir-prefixed atom, which is what
      # Code.compile_string returns for module results.
      [_, name] -> {:ok, Module.concat([name])}
      _ -> {:error, :no_module_name}
    end
  end

  defp mount(runtime, mod, config) do
    entries = current_entries(runtime)
    new_entry = %{id: mod, plugin: mod, config: config, disabled: false}
    desired = Enum.reject(entries, &(&1.id == mod)) ++ [new_entry]

    case DshBeam.Runtime.reconcile(runtime, desired) do
      :ok ->
        {:ok, mod}

      {:error, errors} ->
        # transactional define: a failed mount leaves the composition
        # unchanged, so later reconciles never re-assert a broken plugin
        DshBeam.Runtime.reconcile(runtime, entries)
        {:error, {:mount, errors}}
    end
  end

  defp current_entries(runtime) do
    runtime
    |> DshBeam.Runtime.entries()
    |> Enum.map(fn {_id, %{spec: entry}} -> entry end)
  end

  defp load(mod, binary), do: :code.load_binary(mod, ~c"nofile", binary)

  defp old_code(mod) do
    case :code.get_object_code(mod) do
      {^mod, binary, _file} -> {:ok, binary}
      :error -> {:ok, nil}
    end
  end

  defp purge_and_delete(mod) do
    :code.purge(mod)
    :code.delete(mod)
    :ok
  end

  defp restore_code(mod, nil), do: purge_and_delete(mod)

  defp restore_code(mod, old_binary) do
    purge_and_delete(mod)
    load(mod, old_binary)
  end
end
