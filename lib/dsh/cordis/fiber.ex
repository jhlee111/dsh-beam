defmodule DshBeam.Fiber do
  @moduledoc """
  A fiber: one instantiation of a plugin inside the context (paper §4.1).

  Carries the declared dependencies (coeffects), the provided keys, the
  lifecycle state, and the LIFO accumulator of effect inverses. The context
  owns fiber records; the owner pid ties the record to the plugin process.
  """

  @typedoc """
  Lifecycle state: :inactive (waiting for dependencies), :active (providing
  and resolving), :unloading (withdrawal in progress — dependents draining).
  """
  @type state :: :inactive | :active | :unloading

  @type t :: %__MODULE__{
          id: term(),
          owner: pid(),
          deps: MapSet.t(),
          provides: MapSet.t(),
          state: state(),
          inverses: [DshBeam.Effect.inverse()],
          intercepts: %{optional(atom()) => {module(), atom(), [term()]}}
        }

  defstruct id: nil,
            owner: nil,
            deps: MapSet.new(),
            provides: MapSet.new(),
            state: :inactive,
            inverses: [],
            intercepts: %{}
end
