defmodule Dsh.Plugin.State do
  @moduledoc """
  The GenServer state of a plugin built with use Dsh.Plugin: the context
  binding, the fiber identity and view, plus the plugin's own extra state
  returned from mount/3.
  """

  @type t :: %__MODULE__{
          ctx: pid(),
          id: term(),
          fiber_state: Dsh.Fiber.state(),
          view: map(),
          config: keyword(),
          extra: term()
        }

  defstruct [:ctx, :id, :fiber_state, :view, :config, :extra]
end
