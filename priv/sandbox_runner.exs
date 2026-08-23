# The §6.3 execution boundary's child runtime: untrusted plugin source is
# compiled and executed HERE, in a separate OS process with its own BEAM, so
# every atom, module, and effect of the source stays out of the host VM.
#
# Protocol (one JSON object per line over stdio):
#   host -> child:  {"source": "...", "config": {...}}      (first line)
#                   {"activate": {...}} | {"withdraw": [...]}
#   child -> host:  {"register": {"deps": [...], "provides": {...}}}
#                   {"deactivated": [...]} | {"error": "message"}
#
# The untrusted plugin contract (plain functions, plain data — key names are
# strings, never atoms):
#   mount(config) -> {:ok, deps, provides, extra}   (deps: [string()], provides: %{string() => data})
#   handle_dsh_ready(state) | handle_dsh_activate(view, state) |
#   handle_dsh_withdraw(keys, state) -> {:ok, state}   (all optional)
#
# This script uses only the Elixir standard library (JSON, IO, Code).
defmodule SandboxRunner do
  @moduledoc false

  def main do
    case IO.binread(:line) do
      :eof ->
        :ok

      line ->
        case JSON.decode(line) do
          {:ok, %{"source" => source, "config" => config}} -> run(source, config)
          _ -> announce(%{"error" => "expected {\"source\", \"config\"} as the first line"})
        end
    end
  end

  defp run(source, config) do
    try do
      {mod, deps, provides, extra} = compile_and_mount(source, config)
      announce(%{"register" => %{"deps" => deps, "provides" => provides}})
      state = hook(mod, :handle_dsh_ready, [%{config: config, extra: extra, view: %{}}])
      loop(mod, state)
    rescue
      e -> announce(%{"error" => Exception.message(e)})
    catch
      kind, reason ->
        announce(%{"error" => "uncaught #{inspect(kind)}: #{inspect(reason)}"})
    end
  end

  defp compile_and_mount(source, config) do
    mod = module_name(source)

    {^mod, _binary} =
      case Code.compile_string(source) do
        results when is_list(results) ->
          Enum.find(results, fn {m, binary} -> m == mod and is_binary(binary) end) ||
            raise "source defines no module #{inspect(mod)}"

        other ->
          raise "compile failed: #{inspect(other)}"
      end

    {deps, provides, extra} =
      case mod.mount(config) do
        {:ok, deps, provides, extra} ->
          {deps, provides, extra}

        other ->
          raise "mount/1 must return {:ok, deps, provides, extra}, got: #{inspect(other)}"
      end

    unless is_list(deps) and Enum.all?(deps, &is_binary/1) do
      raise "mount/1 must return deps as a list of key strings, got: #{inspect(deps)}"
    end

    unless is_map(provides) and Enum.all?(Map.keys(provides), &is_binary/1) do
      raise "mount/1 must return provides as a map with string keys, got: #{inspect(provides)}"
    end

    {mod, deps, provides, extra}
  end

  defp module_name(source) do
    case Regex.run(~r/^\s*defmodule\s+([A-Z]\w*)/, source) do
      [_, name] -> Module.concat([name])
      _ -> raise "source defines no module (expected a top-level defmodule)"
    end
  end

  defp loop(mod, state) do
    case IO.binread(:line) do
      :eof ->
        :ok

      line ->
        case JSON.decode(line) do
          {:ok, %{"activate" => view}} when is_map(view) ->
            state = hook(mod, :handle_dsh_activate, [view, %{state | view: view}])
            loop(mod, state)

          {:ok, %{"withdraw" => keys}} when is_list(keys) ->
            state = hook(mod, :handle_dsh_withdraw, [keys, state])
            announce(%{"deactivated" => keys})
            loop(mod, state)

          _ ->
            loop(mod, state)
        end
    end
  end

  defp hook(mod, fun, args) do
    if function_exported?(mod, fun, length(args)) do
      case apply(mod, fun, args) do
        {:ok, state} -> state
        other -> raise "#{inspect(fun)}/#{length(args)} must return {:ok, state}, got: #{inspect(other)}"
      end
    else
      # state is always the last argument; an absent hook is a no-op
      List.last(args)
    end
  end

  defp announce(msg) do
    IO.binwrite(JSON.encode!(msg) <> "\n")
  end
end

SandboxRunner.main()
