defmodule Dsh.Effect do
  @moduledoc """
  Revertible effects — temporal composability (paper §3.1).

  Every context transformation pairs with an inverse. The runtime tracks the
  inverses of a fiber's effects in an accumulator; on teardown the accumulator
  is applied in reverse application order (LIFO), recovering the context to
  its pre-composition state. Inverses are context transformations
  (state -> state), so the accumulator is the twisted composition of the
  paper.
  """

  @typedoc "An inverse: a context transformation that undoes one effect."
  @type inverse :: (term() -> term())

  @typedoc "The LIFO accumulator of a fiber's effect inverses."
  @type accumulator :: [inverse()]

  @doc "Track one effect: prepend its inverse to the accumulator."
  @spec track(accumulator(), inverse()) :: accumulator()
  def track(accumulator, inverse) when is_function(inverse, 1) do
    [inverse | accumulator]
  end

  @doc "Apply the accumulated inverses, recovering the context (recoverΓ)."
  @spec dispose(accumulator(), term()) :: term()
  def dispose(accumulator, state) do
    Enum.reduce(accumulator, state, fn inverse, acc -> inverse.(acc) end)
  end
end
