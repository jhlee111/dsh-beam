defmodule DshBeam.Guard.RepeatToolReminder do
  @moduledoc """
  Advisory loop-breaker — the harness's `guard/repeat-tool-reminder`.

  It never vetoes or rewrites a tool call: it watches the stream of tool calls,
  counts runs of consecutive calls to the SAME tool with IDENTICAL canonicalized
  arguments, and at configured run lengths injects an escalating advisory
  reminder telling the model to stop repeating itself, re-read the last result,
  and either change approach or conclude. The decision stays with the model.

  `track/2` folds one dispatched tool call (name + args) into the repeat state
  and returns `{new_state, reminder | nil}`; `reminder/2` is what the loop
  injects as a user message when the run length hits a threshold.
  """

  @default_thresholds [3, 5, 8]

  @type state :: %{last_key: {String.t(), String.t()} | nil, run: non_neg_integer()}

  @doc "The initial (empty) repeat-tracking state."
  @spec new() :: state()
  def new, do: %{last_key: nil, run: 0}

  @doc """
  Fold one dispatched call into the state. Returns `{new_state, reminder}` where
  `reminder` is nil unless the consecutive-run length just hit a threshold.
  """
  @spec track(state(), String.t(), map(), keyword()) :: {state(), String.t() | nil}
  def track(state, name, args, opts \\ []) do
    thresholds = Keyword.get(opts, :thresholds, @default_thresholds)
    key = {name, canonical(args)}

    {run, reminder} =
      case state do
        %{last_key: ^key, run: run} ->
          new_run = run + 1
          {new_run, reminder_for(name, args, new_run, thresholds)}

        _ ->
          {1, nil}
      end

    {%{last_key: key, run: run}, reminder}
  end

  defp reminder_for(_name, _args, run, thresholds) do
    if run in thresholds do
      {:ok, text} = build_reminder(run)
      text
    else
      nil
    end
  end

  defp build_reminder(3),
    do:
      {:ok,
       "You are repeating the same tool call. Re-read the last result and change approach or conclude."}

  defp build_reminder(run) do
    {:ok,
     "You have called the same tool with identical arguments #{run} times in a row. Stop repeating; re-read the last result, then either try a different approach or finish the task."}
  end

  # canonicalize arguments: deep key-sort + JSON, so argument objects differing
  # only in property order count as identical
  defp canonical(args) when is_map(args) do
    args
    |> deep_sort()
    |> JSON.encode!()
  end

  defp canonical(args), do: inspect(args)

  defp deep_sort(map) when is_map(map) do
    map
    |> Enum.sort_by(fn {k, _} -> to_string(k) end)
    |> Enum.map(fn {k, v} -> {k, deep_sort(v)} end)
    |> Map.new()
  end

  defp deep_sort(list) when is_list(list), do: Enum.map(list, &deep_sort/1)
  defp deep_sort(value), do: value
end
