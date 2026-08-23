defmodule DshBeam.Provider do
  @moduledoc """
  A generic plugin that provides arbitrary key/value bindings — the minimal
  shape of every capability provider.
  """

  use DshBeam.Plugin

  @impl DshBeam.Plugin
  def mount(_ctx, opts) do
    {:ok, Keyword.get(opts, :deps, []), Keyword.fetch!(opts, :provides), %{}}
  end
end
