defmodule DshBeamWeb.IconsTest do
  use ExUnit.Case, async: true

  # Function components are plain functions; calling them directly with an
  # explicit assigns map (the `attr` defaults only apply through the `~H`
  # component macro) renders their SVG.
  defp render(component) do
    component |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary()
  end

  test "outline icons render an svg with currentColor fill" do
    for component <- [
          DshBeamWeb.Icons.chevron_down(%{size: 14, class: nil}),
          DshBeamWeb.Icons.chevron_right(%{size: 14, class: nil}),
          DshBeamWeb.Icons.check(%{size: 16, class: nil}),
          DshBeamWeb.Icons.warning(%{size: 14, class: nil}),
          DshBeamWeb.Icons.plus(%{size: 16, class: nil}),
          DshBeamWeb.Icons.search(%{size: 16, class: nil}),
          DshBeamWeb.Icons.send(%{size: 16, class: nil}),
          DshBeamWeb.Icons.stop(%{size: 16, class: nil})
        ] do
      html = render(component)
      assert html =~ "<svg"
      assert html =~ "currentColor"
    end
  end

  test "shield renders a distinct glyph per permission mode" do
    assert render(DshBeamWeb.Icons.shield(%{mode: :read_only, size: 16, class: nil})) =~
             "viewBox=\"0 0 16 16\""

    # each mode draws its overlay; the outline path is shared by read-only
    # and full-access, the pencil glyph is unique to workspace-write
    assert render(DshBeamWeb.Icons.shield(%{mode: :workspace_write, size: 16, class: nil})) =~
             "currentColor"

    assert render(DshBeamWeb.Icons.shield(%{mode: :full_access, size: 16, class: nil})) =~
             "currentColor"
  end
end
