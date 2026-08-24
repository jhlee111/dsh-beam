defmodule DshBeam.Ui.Panel.ModelSelect do
  @moduledoc """
  The composer's model seat — the reference `ModelSelect`: a trigger showing
  `model · effort`, and a two-level menu (root Model/Effort rows → provider-
  grouped model list / effort list). It renders into the `:composer_toolbar`
  slot; the roster comes from `DshBeam.Llm.Models`, and the current model/effort
  from the console's `@llm_config` (`DshBeam.Llm.Plugin`).
  """

  use DshBeam.Plugin
  import Phoenix.Component

  ui_slot(:composer_toolbar, kind: :list, order: 20, component: {__MODULE__, :panel, []})

  def panel(assigns) do
    ~H"""
    <%= if @llm_config do %>
    <div class="model-seat">
      <button
        type="button"
        class="model-trigger"
        phx-click="model_toggle"
        aria-haspopup="menu"
        aria-expanded={@model_open}
        disabled={@chat_busy}
      >
        <span class="model-name"><%= @llm_config.model %></span>
        <%= if effort_label(@llm_config) do %>
          <span class="model-effort">· <%= effort_label(@llm_config) %></span>
        <% end %>
        <DshBeamWeb.Icons.chevron_down class={"model-chevron #{if @model_open, do: "open"}"} />
      </button>

      <%= if @model_open do %>
        <div class="model-menu" role="menu">
          <%= if @model_pane == :root do %>
            <button type="button" role="menuitem" class="model-cell" phx-click="model_pane" phx-value-pane="model">
              <span class="model-cell-label">Model</span>
              <span class="model-cell-value"><%= @llm_config.model %></span>
              <DshBeamWeb.Icons.chevron_right class="model-cell-chevron" />
            </button>
            <%= if reasoning?(@llm_config.model) do %>
              <button type="button" role="menuitem" class="model-cell" phx-click="model_pane" phx-value-pane="effort">
                <span class="model-cell-label">Effort</span>
                <span class="model-cell-value"><%= effort_label(@llm_config) %></span>
                <DshBeamWeb.Icons.chevron_right class="model-cell-chevron" />
              </button>
            <% end %>
          <% else %>
            <%= if @model_pane == :model do %>
              <%= for group <- DshBeam.Llm.Models.groups() do %>
                <div class="model-group-title"><%= group.name %></div>
                <%= for model <- group.models do %>
                  <button
                    type="button"
                    role="menuitemradio"
                    aria-checked={model.id == @llm_config.model}
                    class={"model-option #{if model.id == @llm_config.model, do: "selected"}"}
                    phx-click="model_select"
                    phx-value-model={model.id}
                  >
                    <span class="model-option-copy">
                      <span class="model-option-name"><%= model.name %></span>
                      <span class="model-option-desc"><%= model.description %></span>
                    </span>
                    <%= if model.id == @llm_config.model do %>
                      <DshBeamWeb.Icons.check class="model-check" />
                    <% end %>
                  </button>
                <% end %>
              <% end %>
            <% else %>
              <%= for level <- efforts(@llm_config.model) do %>
                <button
                  type="button"
                  role="menuitemradio"
                  aria-checked={level.id == @llm_config.reasoning_effort}
                  class={"model-option #{if level.id == @llm_config.reasoning_effort, do: "selected"}"}
                  phx-click="model_effort_select"
                  phx-value-effort={level.id}
                >
                  <span class="model-option-copy">
                    <span class="model-option-name"><%= level.name %></span>
                    <span class="model-option-desc"><%= level.description %></span>
                  </span>
                  <%= if level.id == @llm_config.reasoning_effort do %>
                    <DshBeamWeb.Icons.check class="model-check" />
                  <% end %>
                </button>
              <% end %>
            <% end %>
          <% end %>
        </div>
      <% end %>
    </div>
    <% end %>
    """
  end

  defp reasoning?(model_id) do
    DshBeam.Llm.Models.reasoning(model_id) != nil
  end

  defp efforts(model_id) do
    case DshBeam.Llm.Models.reasoning(model_id) do
      %{efforts: efforts} -> efforts
      _ -> []
    end
  end

  defp effort_label(llm_config) do
    case DshBeam.Llm.Models.reasoning(llm_config.model) do
      nil ->
        nil

      %{efforts: efforts} ->
        case Enum.find(efforts, &(&1.id == llm_config.reasoning_effort)) do
          nil -> llm_config.reasoning_effort
          level -> level.name
        end
    end
  end
end
