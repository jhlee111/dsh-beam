defmodule DshBeam.Ui do
  @moduledoc """
  The UI slot composer — the harness's ui-slots renderer, for LiveView
  function components.

  A LiveView calls `DshBeam.Ui.render_slot(slot_name, assigns)` to render every
  plugin's registered contribution to that slot, composed by the slot's kind:

  - `:single` — the single occupant (lowest `order` wins).
  - `:list`    — every occupant, in `order` ascending order.
  - `:keyed`   — one occupant per `key` (passed via `assigns.key`).
  - `:chain`   — the first occupant whose `select` returns truthy for the slot
                context (short-circuit, lowest `order` first).

  A slot component is a function component: `{M, :fun, []}` or a 1-arity fun.
  It receives the caller's `assigns` (plus `:slot` = the slot name), so a
  session-scoped slot can read the session projection from `assigns`.
  """

  @doc """
  Render one slot's contributions. Returns a list of Phoenix.HTML.Safe-safe
  values (rendered component output), usable in `~H` via `<%= ... %>`.
  """
  def render_slot(name, assigns, opts \\ []) when is_atom(name) do
    entries = DshBeam.Ui.Registry.for_slot(name)
    key = Keyword.get(opts, :key)

    entries
    |> compose(key)
    |> Enum.map(fn entry ->
      entry.component
      |> render_component(forwarded(assigns, name))
      |> Phoenix.HTML.Safe.to_iodata()
    end)
  end

  # single: the lowest-order occupant wins
  defp compose([], _key), do: []

  defp compose(entries, key) do
    case kind_of(entries) do
      :single ->
        [Enum.min_by(entries, & &1.order)]

      :keyed ->
        entries
        |> Enum.filter(&(&1.key == key))
        |> Enum.sort_by(& &1.order)

      :chain ->
        chain(Enum.sort_by(entries, & &1.order))

      _list ->
        Enum.sort_by(entries, & &1.order)
    end
  end

  defp kind_of([entry | _]), do: entry.kind

  defp chain([]), do: []

  defp chain([entry | rest]) do
    if select?(entry), do: [entry], else: chain(rest)
  end

  defp select?(%{select: nil}), do: true
  defp select?(%{select: {mod, fun, args}}), do: !!apply(mod, fun, args)
  defp select?(%{select: fun}) when is_function(fun, 0), do: !!fun.()

  defp forwarded(assigns, name) do
    Map.put(assigns, :slot, name)
  end

  defp render_component({mod, fun, args}, assigns) do
    apply(mod, fun, args ++ [assigns])
  end

  defp render_component(fun, assigns) when is_function(fun, 1) do
    fun.(assigns)
  end
end
