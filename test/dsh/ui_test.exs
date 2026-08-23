defmodule DshBeam.UiTest do
  use ExUnit.Case, async: false

  test "slots/1 introspects a plugin's UI slot declarations" do
    assert DshBeam.Plugin.slots(SamplePanelPlugin) == [
             %{
               name: :panels,
               kind: :list,
               scope: :root,
               component: {SamplePanelPlugin, :panel, []},
               order: 10,
               key: nil,
               select: nil
             }
           ]
  end

  test "the UI registry lists installed slots" do
    entry = Enum.find(DshBeam.Ui.Registry.for_slot(:panels), &(&1.plugin == SamplePanelPlugin))
    assert entry != nil
    assert entry.kind == :list
  end

  test "render_slot composes list slots in order" do
    entries = DshBeam.Ui.Registry.for_slot(:ordered_list)
    orders = Enum.map(entries, & &1.order)
    assert orders == [10, 20]
  end

  test "single slot: lowest order wins" do
    # two plugins register :single_slot; render_slot keeps only the lowest order
    html =
      DshBeam.Ui.render_slot(:single_slot, %{})
      |> Phoenix.HTML.Safe.to_iodata()
      |> IO.iodata_to_binary()

    assert html =~ "single-one"
    refute html =~ "single-two"
  end

  test "keyed slot: only the matching key renders" do
    html =
      DshBeam.Ui.render_slot(:keyed_slot, %{}, key: :b)
      |> Phoenix.HTML.Safe.to_iodata()
      |> IO.iodata_to_binary()

    assert html =~ "keyed-b"
    refute html =~ "keyed-a"
  end

  test "chain slot: first matching select wins" do
    html =
      DshBeam.Ui.render_slot(:chain_slot, %{})
      |> Phoenix.HTML.Safe.to_iodata()
      |> IO.iodata_to_binary()

    assert html =~ "chain-even"
    refute html =~ "chain-odd"
  end
end

defmodule SamplePanelPlugin do
  @moduledoc false
  use DshBeam.Plugin
  import Phoenix.Component

  ui_slot(:panels, kind: :list, component: {__MODULE__, :panel, []}, order: 10)

  def panel(assigns) do
    ~H"""
    <div class="panel">sample</div>
    """
  end
end

defmodule DshBeam.Ui.OrderPluginOne do
  @moduledoc false
  use DshBeam.Plugin
  import Phoenix.Component

  ui_slot(:ordered_list, kind: :list, component: {__MODULE__, :panel, []}, order: 10)

  def panel(assigns) do
    ~H"""
    <div id="one">one</div>
    """
  end
end

defmodule DshBeam.Ui.OrderPluginTwo do
  @moduledoc false
  use DshBeam.Plugin
  import Phoenix.Component

  ui_slot(:ordered_list, kind: :list, component: {__MODULE__, :panel, []}, order: 20)

  def panel(assigns) do
    ~H"""
    <div id="two">two</div>
    """
  end
end

defmodule DshBeam.Ui.SingleSlotOne do
  @moduledoc false
  use DshBeam.Plugin
  import Phoenix.Component

  ui_slot(:single_slot, kind: :single, component: {__MODULE__, :panel, []}, order: 5)

  def panel(assigns) do
    ~H"""
    <div id="single-one">one</div>
    """
  end
end

defmodule DshBeam.Ui.SingleSlotTwo do
  @moduledoc false
  use DshBeam.Plugin
  import Phoenix.Component

  ui_slot(:single_slot, kind: :single, component: {__MODULE__, :panel, []}, order: 50)

  def panel(assigns) do
    ~H"""
    <div id="single-two">two</div>
    """
  end
end

defmodule DshBeam.Ui.KeyedSlotA do
  @moduledoc false
  use DshBeam.Plugin
  import Phoenix.Component

  ui_slot(:keyed_slot, kind: :keyed, component: {__MODULE__, :panel, []}, order: 10, key: :a)

  def panel(assigns) do
    ~H"""
    <div id="keyed-a">a</div>
    """
  end
end

defmodule DshBeam.Ui.KeyedSlotB do
  @moduledoc false
  use DshBeam.Plugin
  import Phoenix.Component

  ui_slot(:keyed_slot, kind: :keyed, component: {__MODULE__, :panel, []}, order: 10, key: :b)

  def panel(assigns) do
    ~H"""
    <div id="keyed-b">b</div>
    """
  end
end

defmodule DshBeam.Ui.ChainEven do
  @moduledoc false
  use DshBeam.Plugin
  import Phoenix.Component

  ui_slot(:chain_slot,
    kind: :chain,
    component: {__MODULE__, :panel, []},
    order: 10,
    select: {__MODULE__, :even?, []}
  )

  def even?, do: true

  def panel(assigns) do
    ~H"""
    <div id="chain-even">even</div>
    """
  end
end

defmodule DshBeam.Ui.ChainOdd do
  @moduledoc false
  use DshBeam.Plugin
  import Phoenix.Component

  ui_slot(:chain_slot,
    kind: :chain,
    component: {__MODULE__, :panel, []},
    order: 20,
    select: {__MODULE__, :odd?, []}
  )

  def odd?, do: false

  def panel(assigns) do
    ~H"""
    <div id="chain-odd">odd</div>
    """
  end
end
