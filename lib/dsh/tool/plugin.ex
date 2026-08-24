defmodule DshBeam.Tool.Plugin do
  @moduledoc """
  The self-modification tool: the agent loop can author a plugin from inside a
  workspace, mount it live (`define_plugin`), hot-swap an already-mounted one
  (`redefine_plugin`), or save it as a reusable plugin file for other
  workspaces/projects (`save_plugin`).

  `define_plugin`/`redefine_plugin` are the trusted in-process paths
  (DshBeam.Creator.define/redefine) — the source becomes atoms and runs
  in-process, exactly like the Creator settings surface. `save_plugin` writes
  to the global `~/.dsh/plugins` store that the console loads on boot.
  """

  use DshBeam.Plugin

  tool(:define_plugin,
    description:
      "Compile and mount an Elixir plugin module (use DshBeam.Plugin) into the running harness, in-process",
    parameters: %{
      "type" => "object",
      "properties" => %{
        "source" => %{"type" => "string", "description" => "full Elixir module source"}
      },
      "required" => ["source"]
    }
  )

  tool(:save_plugin,
    description:
      "Save a plugin's Elixir source as a reusable plugin under ~/.dsh/plugins, so other workspaces can load it",
    parameters: %{
      "type" => "object",
      "properties" => %{
        "name" => %{"type" => "string", "description" => "plugin name (becomes <name>.exs)"},
        "source" => %{"type" => "string", "description" => "full Elixir module source"}
      },
      "required" => ["name", "source"]
    }
  )

  tool(:redefine_plugin,
    description:
      "Hot-swap an already-mounted plugin: compile new source for the same module name and replace the running one transactionally (rolls back on a failed start)",
    parameters: %{
      "type" => "object",
      "properties" => %{
        "source" => %{
          "type" => "string",
          "description" => "full Elixir module source (same module name as the mounted one)"
        }
      },
      "required" => ["source"]
    }
  )

  prompt_section(:self_modification,
    order: 100,
    text:
      "You can extend the harness at runtime. To create a plugin: write the Elixir module source (a module using DshBeam.Plugin), then define_plugin it to compile and mount it live, and save_plugin it to persist it under ~/.dsh/plugins so it is reused in other workspaces/projects. To change a plugin that is already mounted, use redefine_plugin with the new source (same module name) — it hot-swaps the running plugin transactionally."
  )

  @impl DshBeam.Plugin
  def handle_dsh_tool_call(:define_plugin, %{"source" => source}, _state) do
    case runtime() do
      {:ok, runtime} -> DshBeam.Creator.define(runtime, source)
      :none -> {:error, :no_runtime}
    end
  end

  def handle_dsh_tool_call(:save_plugin, %{"name" => name, "source" => source}, _state) do
    DshBeam.Creator.save_plugin(name, source)
  end

  def handle_dsh_tool_call(:redefine_plugin, %{"source" => source}, _state) do
    case runtime() do
      {:ok, runtime} -> DshBeam.Creator.redefine(runtime, source)
      :none -> {:error, :no_runtime}
    end
  end

  # The runtime the console owns (and the loop runs in). The console registers
  # it under :persistent_term on mount; without a console there is no runtime
  # to modify.
  defp runtime do
    case :persistent_term.get({DshBeam.Console, :refs}, nil) do
      %{runtime: runtime} when is_pid(runtime) -> {:ok, runtime}
      _ -> :none
    end
  end
end
