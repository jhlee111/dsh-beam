defmodule Dsh.Creator do
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
  and code runs in-process. Sandboxing untrusted creators is the paper's
  §6.3 execution boundary and future work.
  """

  @doc """
  Compile source, load it, and mount it as one plugin entry. Returns
  {:ok, module} or {:error, {:compile, _}} | {:error, {:mount, _}}.
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
      :ok = Dsh.Runtime.reconcile(runtime, Enum.reject(entries, &(&1.id == mod)))

      # 2. swap the code
      purge_and_delete(mod)
      load(mod, binary)

      # 3. start the new fiber; roll back on failure
      case mount(runtime, mod, Keyword.get(opts, :config, [])) do
        {:ok, mod} ->
          {:ok, mod}

        {:error, reason} ->
          restore_code(mod, old_binary)
          Dsh.Runtime.reconcile(runtime, entries)
          {:error, {:start_failed, reason}}
      end
    end
  end

  @doc "Withdraw the plugin fiber and unload its code."
  def undefine(runtime, mod) do
    entries = current_entries(runtime)
    :ok = Dsh.Runtime.reconcile(runtime, Enum.reject(entries, &(&1.id == mod)))
    purge_and_delete(mod)
    :ok
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

    case Dsh.Runtime.reconcile(runtime, desired) do
      :ok -> {:ok, mod}
      {:error, errors} -> {:error, {:mount, errors}}
    end
  end

  defp current_entries(runtime) do
    runtime
    |> Dsh.Runtime.entries()
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
