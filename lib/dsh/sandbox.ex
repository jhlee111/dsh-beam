defmodule DshBeam.Sandbox do
  @moduledoc """
  The §6.3 execution boundary for untrusted plugin source.

  Creator-supplied source is trusted: it compiles and runs in-process.
  define/2 runs untrusted source in a child OS process — its own BEAM — so
  every atom, module, and effect of the source stays out of the host VM. The
  host only sees the plugin's declarations and inert values through the
  boundary (see DshBeam.Sandbox.Plugin).

  Boundary rules:

  - the entry id is a SHA-256 hash of the source, never a name from it;
  - only keys that already exist as atoms on the host (nominal capability
    keys) may be depended on or provided;
  - only JSON-safe data crosses — capabilities (pids) never do;
  - a child crash withdraws through the L-Unload guard (dependents drain
    first) and the runtime re-injects a fresh child.

  define/2 is transactional like Creator.define: a failed mount rolls the
  composition back, so a broken sandboxed plugin is never re-asserted.
  """

  @typedoc "An installed sandboxed plugin: the entry it was mounted under."
  @type install :: DshBeam.Loader.entry()

  @doc """
  Compile and run untrusted source in a sandboxed child process and mount it
  as one plugin entry. Returns {:ok, install} or {:error, {:mount, errors}}.
  """
  @spec define(pid(), String.t(), keyword()) :: {:ok, install()} | {:error, {:mount, term()}}
  def define(runtime, source, opts \\ []) do
    entry = entry_for(source, opts)
    entries = current_entries(runtime)
    desired = Enum.reject(entries, &(&1.id == entry.id)) ++ [entry]

    case DshBeam.Runtime.reconcile(runtime, desired) do
      :ok ->
        {:ok, entry}

      {:error, errors} ->
        # transactional define: a failed mount leaves the composition
        # unchanged, so later reconciles never re-assert a broken plugin
        DshBeam.Runtime.reconcile(runtime, entries)
        {:error, {:mount, errors}}
    end
  end

  @doc "Withdraw a sandboxed plugin (dependents drain first) and return the reconcile result."
  @spec undefine(pid(), install()) :: :ok | {:error, term()}
  def undefine(runtime, %{id: id}) do
    entries = current_entries(runtime)
    DshBeam.Runtime.reconcile(runtime, Enum.reject(entries, &(&1.id == id)))
  end

  defp entry_for(source, opts) do
    hash = :crypto.hash(:sha256, source) |> Base.encode16(case: :lower)

    %{
      id: {:sandbox, hash},
      plugin: DshBeam.Sandbox.Plugin,
      config: [source: source, sandbox_config: Keyword.get(opts, :config, %{})],
      disabled: false
    }
  end

  defp current_entries(runtime) do
    runtime
    |> DshBeam.Runtime.entries()
    |> Enum.map(fn {_id, %{spec: entry}} -> entry end)
  end
end
