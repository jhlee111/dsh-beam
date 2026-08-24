defmodule DshBeam.Ui.TrajectoryProjection do
  @moduledoc """
  The trajectory view's projection — the reference `deriveTrajectoryLayout`
  (turn → groups → cells), on the BEAM. It folds the flat session log into
  turns of typed cells, each carrying a `kind`/`label`/`text` the
  `DshBeam.Ui.Panel.Trajectory` renders as a compact kind-tagged ledger.

  A turn opens at a `turn_start` event (falling back to `user` for logs that
  predate the structural events); the agent loop also records a per-model-call
  `request` event (token usage + wall-clock timing) and a `turn_end` event
  (outcome reason). `turn_start` is a pure boundary and produces no cell.
  Pure and testable; `filter/2` narrows it by a search query without touching
  the log.
  """

  @typedoc "One trajectory cell."
  @type cell :: %{kind: atom(), label: String.t(), text: String.t()}

  @doc "Project the session log into turns of cells (append order)."
  @spec from_events([map()]) :: [[cell()]]
  def from_events(events) do
    events
    |> group_turns()
    |> Enum.map(fn turn ->
      turn
      |> Enum.reject(&(&1["role"] == "turn_start"))
      |> Enum.map(&cell/1)
    end)
  end

  @doc "Map one session event to a trajectory cell."
  @spec cell(map()) :: cell()
  def cell(%{"role" => "user", "content" => content}),
    do: %{kind: :user, label: "USER", text: content}

  def cell(%{"role" => "assistant", "content" => content} = event),
    do: %{kind: :message, label: "ASSISTANT", text: content <> usage_suffix(event["usage"])}

  def cell(%{"role" => "reasoning", "content" => content}),
    do: %{kind: :reasoning, label: "THINK", text: truncate(content)}

  def cell(%{"role" => "tool_call", "name" => name}),
    do: %{kind: :tool, label: "TOOL", text: name}

  def cell(%{"role" => "tool_result", "name" => name, "content" => content}),
    do: %{kind: :tool, label: "TOOL", text: name <> " → " <> truncate(content)}

  def cell(%{"role" => "command_run", "name" => name}),
    do: %{kind: :command, label: "COMMAND", text: "/" <> name}

  def cell(%{"role" => "command_done", "name" => name, "content" => content}),
    do: %{kind: :command, label: "COMMAND", text: "/" <> name <> " · " <> content}

  def cell(%{"role" => "permission_preset", "preset" => preset}),
    do: %{kind: :system, label: "PERMISSION", text: preset}

  def cell(%{"role" => "error", "content" => content}),
    do: %{kind: :error, label: "ERROR", text: content}

  def cell(%{
        "role" => "request",
        "usage" => usage,
        "started_at" => started_at,
        "completed_at" => completed_at
      }),
      do: %{kind: :request, label: "REQUEST", text: request_text(usage, started_at, completed_at)}

  def cell(%{"role" => "turn_end", "reason" => reason}),
    do: %{kind: :turn_end, label: "END", text: reason}

  def cell(other), do: %{kind: :other, label: "EVENT", text: inspect(other)}

  @doc """
  Filter turns by a case-insensitive substring query over cell text. A blank
  query returns the turns unchanged.
  """
  @spec filter([[cell()]], String.t() | nil) :: [[cell()]]
  def filter(turns, query) when query in [nil, ""], do: turns

  def filter(turns, query) do
    needle = String.downcase(query)

    turns
    |> Enum.map(fn turn ->
      Enum.filter(turn, &String.contains?(String.downcase(&1.text), needle))
    end)
    |> Enum.reject(&(&1 == []))
  end

  defp group_turns(events) do
    # A turn opens at turn_start; logs that predate the structural events fall
    # back to the user event as the boundary.
    boundary = if Enum.any?(events, &(&1["role"] == "turn_start")), do: "turn_start", else: "user"

    {turns, current} =
      Enum.reduce(events, {[], []}, fn event, {turns, current} ->
        if event["role"] == boundary do
          {[Enum.reverse(current) | turns], [event]}
        else
          {turns, [event | current]}
        end
      end)

    # `turns` is newest-first and `current` is the in-progress turn (reversed):
    # prepend current, drop empty turns, then reverse into chronological order.
    [Enum.reverse(current) | turns]
    |> Enum.reject(&(&1 == []))
    |> Enum.reverse()
  end

  defp truncate(text) when is_binary(text) do
    if String.length(text) > 120, do: String.slice(text, 0, 120) <> "…", else: text
  end

  defp truncate(text), do: inspect(text)

  # One request's compact summary: wall-clock duration plus token usage.
  defp request_text(usage, started_at, completed_at) do
    duration = completed_at - started_at
    "#{duration}ms" <> usage_suffix(usage)
  end

  # A compact "in/out" token summary for a usage map, or "" when absent.
  defp usage_suffix(nil), do: ""

  defp usage_suffix(usage) when is_map(usage) do
    input = usage[:input_tokens] || 0
    output = usage[:output_tokens] || 0

    if input == 0 and output == 0 do
      ""
    else
      " · #{input} in / #{output} out"
    end
  end

  defp usage_suffix(_), do: ""
end
