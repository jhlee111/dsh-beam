defmodule DshBeam.Ui do
  import Phoenix.Component

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
  Render one slot's contributions. Returns a list of
  `Phoenix.LiveView.Rendered` structs (one per composed occupant).

  The host renders them with a `for` comprehension, so LiveComponents,
  `phx-*` events, and hooks stay wired into the LiveView diff (serializing
  them with `to_iodata` would drop that wiring):

      <%= for rendered <- DshBeam.Ui.render_slot(:details, assigns) do %>
        <%= rendered %>
      <% end %>

  Each contribution is wrapped in a layout-transparent region marker
  (`display: contents`, `data-dsh-region`) carrying the slot name, the plugin
  module that rendered it, and its source file — the ElementSelect picker reads
  these via `closest('[data-dsh-region]')` so a pick marker names the owning
  plugin / slot / source, not just the HTML.
  """
  def render_slot(name, assigns, opts \\ []) when is_atom(name) do
    entries = DshBeam.Ui.Registry.for_slot(name)
    key = Keyword.get(opts, :key)

    entries
    |> compose(key)
    |> Enum.map(fn entry ->
      entry.component
      |> render_component(forwarded(assigns, name))
      |> wrap_region(entry)
    end)
  end

  defp wrap_region(rendered, entry) do
    assigns = %{
      inner: rendered,
      slot: entry.name,
      plugin: entry.plugin |> inspect() |> String.replace("Elixir.", ""),
      source: source_file(entry.plugin),
      key: if(is_nil(entry.key), do: "", else: to_string(entry.key))
    }

    ~H"""
    <span
      style="display: contents"
      data-dsh-region
      data-dsh-slot={@slot}
      data-dsh-plugin={@plugin}
      data-dsh-source={@source}
      data-dsh-key={@key}
    ><%= @inner %></span>
    """
  end

  defp source_file(mod) do
    case mod.module_info(:compile)[:source] do
      nil -> ""
      src when is_list(src) -> src |> List.to_string() |> Path.relative_to_cwd()
      src when is_binary(src) -> Path.relative_to_cwd(src)
    end
  rescue
    _ -> ""
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
