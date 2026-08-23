defmodule Dsh.CoeffectTest do
  use ExUnit.Case, async: true

  test "resolution is satisfied when every declared key is provided" do
    bindings = %{session: :live, storage: :live}

    assert {:satisfied, %{session: :live}} =
             Dsh.Coeffect.resolve(bindings, MapSet.new([:session]))
  end

  test "resolution reports the missing keys" do
    assert {:unsatisfied, %{}, [:session]} =
             Dsh.Coeffect.resolve(%{}, MapSet.new([:session]))
  end

  test "the committed view contains only the declared keys" do
    bindings = %{session: :live, storage: :live}

    assert {:satisfied, %{session: :live}} =
             Dsh.Coeffect.resolve(bindings, MapSet.new([:session]))
  end
end
