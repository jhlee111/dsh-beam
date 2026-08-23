defmodule DshBeam.Tool do
  @moduledoc """
  A tool is a plugin: declared via the `tool` DSL, provided under its name
  (the default mount binds each tool name to the fiber), and invoked through
  that fiber's handle_dsh_tool_call hook.
  """

  @typedoc "The model-facing spec of one declared tool."
  @type spec :: %{name: atom(), description: String.t(), parameters: map()}

  @doc "Invoke one tool on its provider fiber."
  @spec call(pid(), atom(), map()) :: {:ok, term()} | {:error, term()}
  def call(provider, name, args) when is_pid(provider) and is_atom(name) and is_map(args) do
    :gen_statem.call(provider, {:tool_call, name, args})
  end

  @doc "The tool declarations of one plugin module."
  @spec declared(module()) :: [spec()]
  def declared(mod), do: DshBeam.Plugin.tools(mod)
end
