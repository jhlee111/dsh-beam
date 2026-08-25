defmodule DshBeam.Goal do
  @moduledoc """
  Event-sourced same-session goal state — the reference's `dsh-goal`, on the BEAM.

  A goal is one durable completion objective for a session. Every mutation
  appends a `goal_change` session event carrying the complete post-mutation
  snapshot (or a clear tombstone); `current/1` folds that log back. The session
  log is the only durable authority. Continuation permission (activation) is
  process-local and deliberately NOT persisted here — the round driver owns it.

  The pure domain layer mirrors `DshBeam.Permission`: it reads/writes the
  session log and enforces the lifecycle rules; the model-facing tools
  (`DshBeam.Tool.Goal`) and the human `/goal` command are separate consumers.
  """

  @default_max_goal_rounds 256

  @phases ~w(active paused blocked complete)
  @operations ~w(create edit pause resume complete blocked clear)
  # The durable snapshot fields (derived meta — rounds/timestamps — is separate).
  @snapshot_fields ~w(id objective phase blocked_reason max_goal_rounds)

  @typedoc "One goal snapshot (the durable fields, excluding derived meta)."
  @type snapshot :: %{
          required(String.t()) => String.t() | integer() | map() | nil
        }

  @typedoc "The folded current-goal view (snapshot + derived meta)."
  @type view :: %{
          required(String.t()) => String.t() | integer() | map() | nil
        }

  @doc "The deployment default round cap for goals created without one."
  @spec default_max_goal_rounds() :: integer()
  def default_max_goal_rounds, do: @default_max_goal_rounds

  @doc "The durable lifecycle phases, in declaration order."
  @spec phases() :: [String.t()]
  def phases, do: @phases

  @doc "The mutation operations, in declaration order."
  @spec operations() :: [String.t()]
  def operations, do: @operations

  @doc """
  The current goal view, folded from the session log (the last `goal_change`
  event wins), or `nil` when no goal is current. A clear tombstone yields nil.
  """
  @spec current(pid()) :: view() | nil
  def current(session) when is_pid(session) do
    session
    |> DshBeam.Session.all()
    |> Enum.filter(&(&1["role"] == "goal_change"))
    |> List.last()
    |> case do
      nil ->
        nil

      %{"operation" => "clear"} ->
        nil

      %{
        "goal" => snapshot,
        "rounds_started" => rounds,
        "created_at" => created,
        "updated_at" => updated
      } ->
        derive(snapshot, rounds, created, updated)

      _ ->
        nil
    end
  end

  @doc """
  Create one goal from a trimmed, non-empty objective. Rejected when a
  non-complete goal is already current (a completed goal may be replaced).
  Returns `{:ok, view}` or `{:error, reason}`.
  """
  @spec create(pid(), String.t(), keyword()) :: {:ok, view()} | {:error, term()}
  def create(session, objective, opts \\ []) when is_pid(session) and is_binary(objective) do
    objective = String.trim(objective)

    cond do
      objective == "" ->
        {:error, :empty_objective}

      not replaceable?(session) ->
        {:error, :goal_already_current}

      true ->
        now = now_ms()
        max_rounds = Keyword.get(opts, :max_goal_rounds, @default_max_goal_rounds)

        snapshot = %{
          "id" => new_id(),
          "revision" => 1,
          "objective" => objective,
          "phase" => "active",
          "blocked_reason" => nil,
          "max_goal_rounds" => max_rounds
        }

        append_change(session, "create", snapshot, 0, now)
    end
  end

  @doc """
  Mutate the current goal under a compare-and-set fence: `goal_id` and
  `revision` must match the current goal's exact id/revision, or the mutation
  is rejected as stale. `action` is one of `edit`, `pause`, `resume`,
  `complete`, `blocked`.

  Options:
    * `:objective` — replacement objective (edit).
    * `:max_goal_rounds` — replacement round cap (edit).
    * `:blocked_reason` — required free-form explanation (blocked).
    * `:code` — the policy-owned lower-kebab-case code (blocked, default `model-reported`).
  """
  @spec update(pid(), String.t(), integer(), String.t(), keyword()) ::
          {:ok, view()} | {:error, term()}
  def update(session, goal_id, revision, action, opts \\ [])
      when is_pid(session) and is_binary(goal_id) and is_integer(revision) and is_binary(action) do
    case current(session) do
      nil ->
        {:error, :no_goal}

      goal ->
        if goal["id"] == goal_id and goal["revision"] == revision do
          do_update(session, goal, action, opts)
        else
          {:error, :stale_reference}
        end
    end
  end

  @doc """
  Clear the current goal: append a revisioned tombstone and retain the durable
  history. Returns `{:ok, :cleared}` or `{:error, reason}`.
  """
  @spec clear(pid()) :: {:ok, :cleared} | {:error, term()}
  def clear(session) when is_pid(session) do
    case current(session) do
      nil ->
        {:error, :no_goal}

      goal ->
        event = %{
          "role" => "goal_change",
          "operation" => "clear",
          "cleared_id" => goal["id"],
          "cleared_revision" => goal["revision"],
          "cleared_at" => now_ms()
        }

        case DshBeam.Session.append(session, event) do
          {:ok, _seq} -> {:ok, :cleared}
          other -> other
        end
    end
  end

  # -- mutation internals --

  defp do_update(session, goal, "edit", opts) do
    objective = String.trim(opts[:objective] || goal["objective"])
    max_rounds = opts[:max_goal_rounds] || goal["max_goal_rounds"]

    if objective == "" do
      {:error, :empty_objective}
    else
      mutate(session, "edit", goal, %{"objective" => objective, "max_goal_rounds" => max_rounds})
    end
  end

  defp do_update(session, goal, "pause", _opts) do
    if goal["phase"] == "active" do
      mutate(session, "pause", goal, %{"phase" => "paused", "blocked_reason" => nil})
    else
      {:error, :invalid_transition}
    end
  end

  defp do_update(session, goal, "resume", _opts) do
    if goal["phase"] in ["paused", "blocked"] and goal["rounds_started"] < goal["max_goal_rounds"] do
      mutate(session, "resume", goal, %{"phase" => "active", "blocked_reason" => nil})
    else
      {:error, :invalid_transition}
    end
  end

  defp do_update(session, goal, "complete", _opts) do
    if goal["phase"] == "active" do
      mutate(session, "complete", goal, %{"phase" => "complete", "blocked_reason" => nil})
    else
      {:error, :invalid_transition}
    end
  end

  defp do_update(session, goal, "blocked", opts) do
    if goal["phase"] == "active" do
      message = String.trim(opts[:blocked_reason] || opts[:message] || "")

      if message == "" do
        {:error, :blocked_reason_required}
      else
        code = opts[:code] || "model-reported"

        mutate(session, "blocked", goal, %{
          "phase" => "blocked",
          "blocked_reason" => %{"code" => code, "message" => message}
        })
      end
    else
      {:error, :invalid_transition}
    end
  end

  defp do_update(_session, _goal, _action, _opts), do: {:error, :unknown_action}

  # Build the next snapshot (current snapshot + extra fields + revision bump)
  # and append it. The revision is the compare-and-set token: create is 1 and
  # every accepted mutation increments it.
  defp mutate(session, operation, goal, extra) do
    snapshot =
      goal
      |> Map.take(@snapshot_fields)
      |> Map.merge(extra)
      |> Map.put("revision", goal["revision"] + 1)

    append_change(session, operation, snapshot, goal["rounds_started"], goal["created_at"])
  end

  # -- helpers --

  # Create is allowed when nothing is current or the current goal is complete.
  defp replaceable?(session) do
    case current(session) do
      nil -> true
      %{"phase" => "complete"} -> true
      _ -> false
    end
  end

  defp append_change(session, operation, snapshot, rounds, created) do
    now = now_ms()

    event = %{
      "role" => "goal_change",
      "operation" => operation,
      "goal" => snapshot,
      "rounds_started" => rounds,
      "created_at" => created,
      "updated_at" => now
    }

    case DshBeam.Session.append(session, event) do
      {:ok, _seq} -> {:ok, derive(snapshot, rounds, created, now)}
      other -> other
    end
  end

  defp derive(snapshot, rounds, created, updated) do
    snapshot
    |> Map.put("rounds_started", rounds)
    |> Map.put("created_at", created)
    |> Map.put("updated_at", updated)
  end

  defp new_id, do: Integer.to_string(System.unique_integer([:positive, :monotonic]))

  defp now_ms, do: System.system_time(:millisecond)
end
