defmodule DshBeam.Ui.ChatEntry do
  @moduledoc """
  One conversation entry, rendered in the reference's shape: a right-aligned
  user bubble, a left-aligned assistant markdown block, a terminal-style tool
  call card, and **collapsed** reasoning/tool-result rows (the reference's
  anti-overwhelm UX — a run of tool calls stays a scannable list of one-line
  summaries, each expandable on demand). Shared by the Chat tab and the
  Trajectory tab, which group the same entries by turn.
  """

  use Phoenix.Component

  attr(:entry, :map, required: true)

  def render(assigns) do
    ~H"""
    <%= case @entry.kind do %>
      <% :user -> %>
        <div class="msg-user"><div class="bubble"><%= @entry.content %></div></div>
      <% :assistant -> %>
        <div class="msg-assistant">
          <span class="role-icon role-assistant" aria-hidden="true">✦</span>
          <div class="markdown"><%= markdown(@entry.content) %></div>
          <button type="button" class="copy-action" data-copy={@entry.content} aria-label="copy">
            <DshBeamWeb.Icons.copy />
          </button>
        </div>
      <% :reasoning -> %>
        <details class="reasoning-row">
          <summary>
            <DshBeamWeb.Icons.think size={14} class="reasoning-icon" />
            <span class="reasoning-title">Think</span>
            <span class="row-sep" aria-hidden="true"></span>
            <span class="row-summary"><%= first_line(@entry.content) %></span>
          </summary>
          <div class="reasoning-body"><%= @entry.content %></div>
        </details>
      <% :tool_call -> %>
        <div class="tool-card">
          <span class="tool-label">
            <span class="role-icon role-tool" aria-hidden="true">❯</span>
            tool_call · <%= @entry.name %>
          </span>
          <code class="tool-command">$ <%= @entry.command %></code>
        </div>
      <% :tool_result -> %>
        <details class="tool-result">
          <summary class="tool-result-summary">
            <span class="tool-label">
              <span class="role-icon role-tool" aria-hidden="true">⏎</span>
              tool_result · <%= @entry.name %>
            </span>
            <span class="row-sep" aria-hidden="true"></span>
            <span class="row-summary"><%= first_line(@entry.content) %></span>
          </summary>
          <pre><%= @entry.content %></pre>
        </details>
      <% :error -> %>
        <div class="msg-error">
          <span class="role-icon role-error" aria-hidden="true">⚠</span>
          <code><%= @entry.content %></code>
        </div>
      <% :command_run -> %>
        <div class="command-card">
          <span class="tool-label">
            <span class="role-icon role-tool" aria-hidden="true">❯</span>
            /<%= @entry.name %><%= if @entry.args != "", do: " " <> @entry.args %>
          </span>
        </div>
      <% :command_done -> %>
        <div class="command-card command-done">
          <span class="tool-label">
            <span class="role-icon role-tool" aria-hidden="true">⏎</span>
            /<%= @entry.name %> · <%= @entry.content %>
          </span>
        </div>
      <% _ -> %>
        <div class="msg-event"><code><%= @entry.content %></code></div>
    <% end %>
    """
  end

  defp markdown(text) do
    text
    |> Earmark.as_html!()
    |> Phoenix.HTML.raw()
  end

  # The collapsed one-line summary: the first line, trimmed and truncated (the
  # reference shows firstLine(text) when settled, latestLine while streaming).
  defp first_line(text) do
    line = text |> String.split("\n", parts: 2) |> hd() |> String.trim()

    if String.length(line) > 140 do
      String.slice(line, 0, 140) <> "…"
    else
      line
    end
  end
end
