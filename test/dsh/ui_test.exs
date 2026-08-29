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
      |> Enum.map(&Phoenix.HTML.Safe.to_iodata/1)
      |> IO.iodata_to_binary()

    assert html =~ "single-one"
    refute html =~ "single-two"
  end

  test "keyed slot: only the matching key renders" do
    html =
      DshBeam.Ui.render_slot(:keyed_slot, %{}, key: :b)
      |> Enum.map(&Phoenix.HTML.Safe.to_iodata/1)
      |> IO.iodata_to_binary()

    assert html =~ "keyed-b"
    refute html =~ "keyed-a"
  end

  test "chain slot: first matching select wins" do
    html =
      DshBeam.Ui.render_slot(:chain_slot, %{})
      |> Enum.map(&Phoenix.HTML.Safe.to_iodata/1)
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

defmodule DshBeam.Ui.ElementSelectMarkerTest do
  use ExUnit.Case, async: true

  test "marker/1 builds a readable marker from a pick payload" do
    marker =
      DshBeam.Ui.Panel.ElementSelect.marker(%{
        "tag" => "button",
        "id" => "composer-send",
        "classes" => "composer-send",
        "selector" => "form.composer > .composer-actions > button.composer-send",
        "text" => "send",
        "html" => "<button class=\"composer-send\">send</button>",
        "region" => %{
          "slot" => "composer_toolbar",
          "plugin" => "DshBeam.Ui.Panel.Command",
          "source" => "lib/dsh/ui/panel/command.ex",
          "key" => ""
        }
      })

    assert marker =~ "[요소 지적] button#composer-send .composer-send"
    assert marker =~ "슬롯: :composer_toolbar"
    assert marker =~ "플러그인: DshBeam.Ui.Panel.Command"
    assert marker =~ "소스: lib/dsh/ui/panel/command.ex"
    assert marker =~ "셀렉터: form.composer > .composer-actions > button.composer-send"
    assert marker =~ "내용: \"send\""
    assert marker =~ "HTML: <button class=\"composer-send\">send</button>"
  end

  test "marker/1 tolerates a sparse payload" do
    marker = DshBeam.Ui.Panel.ElementSelect.marker(%{"selector" => "div.foo"})
    assert marker =~ "[요소 지적] element"
    assert marker =~ "셀렉터: div.foo"
    refute marker =~ "내용:"
    refute marker =~ "슬롯:"
  end

  test "marker/1 includes the keyed-slot key in the region context" do
    marker =
      DshBeam.Ui.Panel.ElementSelect.marker(%{
        "selector" => "section",
        "region" => %{
          "slot" => "settings_section",
          "plugin" => "DshBeam.Ui.Panel.Plugins",
          "source" => "lib/dsh/ui/panel.ex",
          "key" => "plugins"
        }
      })

    assert marker =~ "슬롯: :settings_section (key: plugins)"
    assert marker =~ "플러그인: DshBeam.Ui.Panel.Plugins"
    assert marker =~ "소스: lib/dsh/ui/panel.ex"
  end
end
