defmodule Dsh.EffectTest do
  use ExUnit.Case, async: true

  test "dispose applies tracked inverses in reverse application order (LIFO)" do
    accumulator =
      []
      |> Dsh.Effect.track(fn state -> [:first | state] end)
      |> Dsh.Effect.track(fn state -> [:second | state] end)
      |> Dsh.Effect.track(fn state -> [:third | state] end)

    assert Dsh.Effect.dispose(accumulator, []) == [:first, :second, :third]
  end

  test "each inverse undoes only its own step" do
    add_a = fn state -> ["a" | state] end
    remove_a = fn ["a" | rest] -> rest end
    add_b = fn state -> ["b" | state] end
    remove_b = fn ["b" | rest] -> rest end

    # effects applied a, then b
    state = add_b.(add_a.([:seed]))

    # inverses accumulated in application order; dispose applies them LIFO
    accumulator = [] |> Dsh.Effect.track(remove_a) |> Dsh.Effect.track(remove_b)

    assert Dsh.Effect.dispose(accumulator, state) == [:seed]
  end
end
