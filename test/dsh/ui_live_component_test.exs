defmodule DshBeam.UiLiveComponentTest do
  # Direction-A POC: a plugin UI slot that hosts a *stateful* LiveComponent
  # (own state + own handle_event), rendered through the console's slot path.
  # Before direction A, `render_slot` serialized the slot to raw HTML via
  # to_iodata, which raises on a LiveComponent ("component must be returned
  # directly as part of a LiveView template").
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint DshBeamWeb.Endpoint

  setup do
    previous_key = System.get_env("DEEPSEEK_API_KEY")
    System.delete_env("DEEPSEEK_API_KEY")

    on_exit(fn ->
      if previous_key, do: System.put_env("DEEPSEEK_API_KEY", previous_key)
    end)

    runtime =
      start_supervised!(%{
        id: {:dsh_runtime, make_ref()},
        start: {DshBeam.Runtime, :start_link, [[], []]}
      })

    console_entry = %{id: :console, plugin: DshBeam.Console, config: [], disabled: false}
    :ok = DshBeam.Runtime.reconcile(runtime, [console_entry])

    ctx = DshBeam.Runtime.context(runtime)
    session = %{"runtime" => encode(runtime), "ctx" => encode(ctx)}

    %{session: session}
  end

  test "a slot can host a stateful LiveComponent with its own events", %{session: session} do
    {:ok, view, _html} = live(build_conn(), "/", session: session)

    # the POC slot renders into :details; seed mounts the demo composition so
    # the details pane is live, then the LiveComponent's own state/events work
    _ = render_submit(view, "seed", %{})

    html = render(view)
    assert html =~ "poc-count"
    assert html =~ "count: 0"

    html = view |> element("#poc-inc") |> render_click()
    assert html =~ "count: 1"
  end

  defp encode(term), do: term |> :erlang.term_to_binary() |> Base.encode64()
end

defmodule DshBeam.Ui.PocCounter do
  @moduledoc false
  use Phoenix.LiveComponent

  def mount(socket), do: {:ok, assign(socket, count: 0)}

  def handle_event("inc", _params, socket) do
    {:noreply, update(socket, :count, &(&1 + 1))}
  end

  def render(assigns) do
    ~H"""
    <div id="poc-root">
      <span id="poc-count">count: <%= @count %></span>
      <button id="poc-inc" type="button" phx-click="inc" phx-target={@myself}>+</button>
    </div>
    """
  end
end

defmodule DshBeam.Ui.PocSlotPlugin do
  @moduledoc false
  use DshBeam.Plugin
  import Phoenix.Component

  ui_slot(:details, kind: :list, order: 1, component: {__MODULE__, :panel, []})

  def panel(assigns) do
    ~H"""
    <section id="poc-slot">
      <.live_component module={DshBeam.Ui.PocCounter} id="poc-counter" />
    </section>
    """
  end
end
