defmodule DshBeam.Tool.Plugin do
  @moduledoc """
  The self-modification tool: the agent loop can author a plugin from inside a
  workspace and either mount it live (`define_plugin`) or save it as a
  reusable plugin file for other workspaces/projects (`save_plugin`).

  `define_plugin` is the trusted in-process path (DshBeam.Creator.define) — the
  source becomes atoms and runs in-process, exactly like the Creator settings
  surface. `save_plugin` writes to the global `~/.dsh/plugins` store that the
  console loads on boot.
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
