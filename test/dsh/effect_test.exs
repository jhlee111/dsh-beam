defmodule DshBeam.EffectTest do
  use ExUnit.Case, async: true

  test "dispose applies tracked inverses in reverse application order (LIFO)" do
    accumulator =
      []
      |> DshBeam.Effect.track(fn state -> [:first | state] end)
      |> DshBeam.Effect.track(fn state -> [:second | state] end)
      |> DshBeam.Effect.track(fn state -> [:third | state] end)

    assert DshBeam.Effect.dispose(accumulator, []) == [:first, :second, :third]
  end

  test "each inverse undoes only its own step" do
    add_a = fn state -> ["a" | state] end
    remove_a = fn ["a" | rest] -> rest end
    add_b = fn state -> ["b" | state] end
    remove_b = fn ["b" | rest] -> rest end

    # effects applied a, then b
    state = add_b.(add_a.([:seed]))

    # inverses accumulated in application order; dispose applies them LIFO
    accumulator = [] |> DshBeam.Effect.track(remove_a) |> DshBeam.Effect.track(remove_b)

    assert DshBeam.Effect.dispose(accumulator, state) == [:seed]
  end
end
