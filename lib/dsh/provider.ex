defmodule Dsh.Provider do
  @moduledoc """
  A generic plugin that provides arbitrary key/value bindings — the minimal
  shape of every capability provider.
  """

  use Dsh.Plugin

  @impl Dsh.Plugin
  def mount(_ctx, opts) do
    {:ok, Keyword.get(opts, :deps, []), Keyword.fetch!(opts, :provides), %{}}
  end
end
