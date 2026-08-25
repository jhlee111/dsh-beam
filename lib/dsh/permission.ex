defmodule DshBeam.Permission do
  @moduledoc """
  Permission presets — the reference's `dsh-permission-presets`, on the BEAM.

  A preset is a named bundle of two knobs: a sandbox mode and an approval
  policy. Applying one appends a durable `permission_preset` session event
  (the reference's log-only `permission/preset`); `current/1` and
  `select_for/1` fold that log back to the value the composer "Access" seat
  renders. This module is the pure domain layer — enforcement (sandbox
  confinement + approval gating) reads the same fold from the tool/sandbox
  plugins, which is the guard-rail seam the README lists as the top wish-list
  item.
  """

  @presets %{
    "read-only" => %{
      sandbox: :read_only,
      approval: :ask,
      name: "Read Only",
      description: "Read the workspace without writing changes."
    },
    "workspace-write" => %{
      sandbox: :workspace_write,
      approval: :ask,
      name: "Workspace Write",
      description:
        "Write inside the workspace and permitted temporary directories; wider retries require approval."
    },
    "danger-full-access" => %{
      sandbox: :danger_full_access,
      approval: :never,
      name: "Full access",
      description: "Full file access without approval prompts."
    }
  }

  @default_preset "workspace-write"

  # Declaration order is the menu order (the reference's `selectFor`).
  @preset_order ["read-only", "workspace-write", "danger-full-access"]

  @typedoc "A preset id (the machine value)."
  @type preset_id :: String.t()

  @typedoc "The sandbox mode a preset maps to."
  @type sandbox_mode :: :read_only | :workspace_write | :danger_full_access

  @typedoc "The approval policy a preset maps to."
  @type approval_policy :: :ask | :never

  @doc "The shipped preset table, keyed by machine id."
  @spec presets() :: %{
          preset_id() => %{
            sandbox: sandbox_mode(),
            approval: approval_policy(),
            name: String.t(),
            description: String.t()
          }
        }
  def presets, do: @presets

  @doc "The preset ids in declaration (menu) order."
  @spec order() :: [preset_id()]
  def order, do: @preset_order

  @doc "The default preset for sessions without an explicit choice."
  @spec default_preset() :: preset_id()
  def default_preset, do: @default_preset

  @doc """
  Apply a preset: append a durable `permission_preset` event to the session
  (the single source of truth), like the reference's log-only permission/preset.
  Returns `{:ok, seq}` or `{:error, :unknown_preset}`.
  """
  @spec apply(pid(), preset_id()) :: {:ok, integer()} | {:error, :unknown_preset}
  def apply(session, preset_id) when is_pid(session) do
    if Map.has_key?(@presets, preset_id) do
      DshBeam.Session.append(session, %{"role" => "permission_preset", "preset" => preset_id})
    else
      {:error, :unknown_preset}
    end
  end

  @doc """
  The current preset id, folded from the session log (the last
  `permission_preset` event wins); falls back to the default before any apply.
  """
  @spec current(pid()) :: preset_id()
  def current(session) when is_pid(session) do
    session
    |> DshBeam.Session.all()
    |> Enum.filter(&(&1["role"] == "permission_preset"))
    |> List.last()
    |> case do
      %{"preset" => id} when is_binary(id) -> id
      _ -> @default_preset
    end
  end

  @doc """
  The value shape the composer "Access" seat renders (the reference's
  `PermissionSelect`): the current value plus the selectable options.
  """
  @spec select_for(pid()) :: %{current_value: preset_id(), options: [map()]}
  def select_for(session) when is_pid(session) do
    %{
      current_value: current(session),
      options:
        Enum.map(@preset_order, fn id ->
          p = Map.fetch!(@presets, id)
          %{value: id, name: p.name, description: p.description}
        end)
    }
  end

  @doc "The preset's sandbox mode, by id (nil for unknown)."
  @spec sandbox_mode(preset_id()) :: sandbox_mode() | nil
  def sandbox_mode(preset_id) do
    case Map.fetch(@presets, preset_id) do
      {:ok, preset} -> preset.sandbox
      :error -> nil
    end
  end

  @doc "The preset's approval policy, by id (nil for unknown)."
  @spec approval_policy(preset_id()) :: approval_policy() | nil
  def approval_policy(preset_id) do
    case Map.fetch(@presets, preset_id) do
      {:ok, preset} -> preset.approval
      :error -> nil
    end
  end
end
