defmodule Dsh.Coeffect do
  @moduledoc """
  Reactive coeffects — spatial composability (paper §3.2).

  A fiber declares dependency keys; resolution yields the committed view and
  whether every declaration is satisfied. The context drives activation and
  deactivation from this same resolution.
  """

  @typedoc "The coeffect store: key to provided value."
  @type bindings :: %{optional(atom()) => term()}

  @typedoc "One fiber's declared dependency keys."
  @type deps :: MapSet.t()

  @typedoc "The committed view: declared keys to their resolved values."
  @type view :: %{optional(atom()) => term()}

  @doc """
  Resolve deps against bindings.

  Returns {:satisfied, view} when every declared key is provided, or
  {:unsatisfied, view, missing} naming the keys that are not.
  """
  @spec resolve(bindings(), deps()) ::
          {:satisfied, view()} | {:unsatisfied, view(), [atom()]}
  def resolve(bindings, deps) do
    keys = MapSet.to_list(deps)
    missing = Enum.filter(keys, &(not Map.has_key?(bindings, &1)))
    view = Map.take(bindings, keys)

    if missing == [] do
      {:satisfied, view}
    else
      {:unsatisfied, view, missing}
    end
  end
end
