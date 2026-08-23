defmodule DshBeam.Ui.ChatEntry do
  @moduledoc """
  One conversation entry, rendered in the reference's shape: a right-aligned
  user bubble, a left-aligned assistant markdown block, a terminal-style tool
  call card, a tool result block, and error/event rows. Shared by the Chat tab
  and the Trajectory tab, which group the same entries by turn.
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
        </div>
      <% :tool_call -> %>
        <div class="tool-card">
          <span class="tool-label">
            <span class="role-icon role-tool" aria-hidden="true">❯</span>
            tool_call · <%= @entry.name %>
          </span>
          <code class="tool-command">$ <%= @entry.command %></code>
        </div>
      <% :tool_result -> %>
        <div class="tool-result">
          <span class="tool-label">
            <span class="role-icon role-tool" aria-hidden="true">⏎</span>
            tool_result · <%= @entry.name %>
          </span>
          <pre><%= @entry.content %></pre>
        </div>
      <% :error -> %>
        <div class="msg-error">
          <span class="role-icon role-error" aria-hidden="true">⚠</span>
          <code><%= @entry.content %></code>
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
end
