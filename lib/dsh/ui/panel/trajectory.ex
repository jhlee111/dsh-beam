defmodule DshBeam.Ui.Panel.Trajectory do
  @moduledoc """
  The trajectory view — the reference `TrajectoryView` ledger, on the BEAM. It
  renders the session log projected by `DshBeam.Ui.TrajectoryProjection` into
  turns of kind-tagged cells: a search toolbar, a per-turn header, and one
  compact row per cell (kind icon + label + text). The reference's timeline and
  virtualized table remain future work (they need per-request usage/timing
  fields the session log does not yet record).
  """

  use DshBeam.Plugin
  import Phoenix.Component

  ui_slot(:conversation,
    kind: :keyed,
    order: 30,
    key: :trajectory,
    component: {__MODULE__, :panel, []}
  )

  def panel(assigns) do
    ~H"""
    <section>
      <h2>trajectory</h2>
      <div class="trajectory-toolbar">
        <span class="trajectory-search-icon"><DshBeamWeb.Icons.search size={11} /></span>
        <input
          type="search"
          name="query"
          value={@trajectory_query}
          phx-change="trajectory_search"
          phx-debounce="200"
          placeholder="search trajectory"
        />
      </div>
      <div class="scroll">
        <%= if @trajectory == [] do %>
          <p class="muted">no turns yet — the chat pane appends them</p>
        <% end %>
        <%= for {turn, index} <- Enum.with_index(@trajectory) do %>
          <div class="trajectory-turn">
            <strong class="muted">turn <%= index + 1 %></strong>
            <div class="trajectory-cells">
              <%= for cell <- turn do %>
                <div class={"trajectory-cell kind-#{cell.kind}"}>
                  <span class="trajectory-tag">
                    <%= case cell.kind do %>
                      <% :user -> %>
                        <DshBeamWeb.Icons.user size={13} />
                      <% :message -> %>
                        <DshBeamWeb.Icons.sparkle size={13} />
                      <% :reasoning -> %>
                        <DshBeamWeb.Icons.think size={13} />
                      <% :tool -> %>
                        <span class="tag-glyph">❯</span>
                      <% :command -> %>
                        <span class="tag-glyph">/</span>
                      <% :system -> %>
                        <span class="tag-glyph">⚙</span>
                      <% :error -> %>
                        <span class="tag-glyph">⚠</span>
                      <% :request -> %>
                        <span class="tag-glyph">◷</span>
                      <% :turn_end -> %>
                        <span class="tag-glyph">✓</span>
                      <% _ -> %>
                        <span class="tag-glyph">·</span>
                    <% end %>
                    <span class="tag-label"><%= cell.label %></span>
                  </span>
                  <span class="trajectory-text"><%= cell.text %></span>
                </div>
              <% end %>
            </div>
          </div>
        <% end %>
      </div>
    </section>
    """
  end
end
