defmodule DshBeam.Tool.Goal do
  @moduledoc """
  The model-facing goal tools — the reference's `dsh-tool-goal`, on the BEAM.

  Exposes `get_goal`, `create_goal`, and `update_goal` over `DshBeam.Goal` (the
  pure event-sourced domain). The tools only mutate durable state; the
  same-session continuation driver and the human `/goal` command are separate
  consumers of the same domain.
  """

  use DshBeam.Plugin

  need(:session)

  @update_actions ~w(edit pause resume complete blocked)

  tool(:get_goal,
    description: "Return the current completion goal and its exact id/revision for updates",
    parameters: %{"type" => "object", "properties" => %{}}
  )

  tool(:create_goal,
    description:
      "Create one long-running completion objective for the current session (single current goal)",
    parameters: %{
      "type" => "object",
      "properties" => %{
        "objective" => %{"type" => "string", "description" => "The completion objective"},
        "max_goal_rounds" => %{
          "type" => "integer",
          "description" => "Optional positive round cap"
        }
      },
      "required" => ["objective"]
    }
  )

  tool(:update_goal,
    description:
      "Mutate the current goal (edit/pause/resume/complete/blocked) under a compare-and-set fence",
    parameters: %{
      "type" => "object",
      "properties" => %{
        "goal_id" => %{"type" => "string", "description" => "The exact id from get_goal"},
        "revision" => %{"type" => "integer", "description" => "The exact revision from get_goal"},
        "action" => %{
          "type" => "string",
          "enum" => @update_actions,
          "description" => "The lifecycle mutation to apply"
        },
        "objective" => %{"type" => "string", "description" => "Replacement objective (edit)"},
        "max_goal_rounds" => %{
          "type" => "integer",
          "description" => "Replacement round cap (edit)"
        },
        "blocked_reason" => %{
          "type" => "string",
          "description" => "Required concrete explanation (blocked)"
        }
      },
      "required" => ["goal_id", "revision", "action"]
    }
  )

  prompt_section(:goal_policy,
    order: 40,
    text:
      "Use goal tools for one long-running completion objective in the current session. create_goal may infer goal intent from a direct human request in any language; do not create a goal for routine single-turn work. Call get_goal before update_goal and copy its exact goal_id and revision. When a human asks to continue or resume in any wording or language, use update_goal action resume to rearm it. Mark complete only when the objective is actually achieved. Mark blocked only after the same blocking condition persists for at least 3 consecutive goal rounds, and report that concrete condition in blocked_reason; difficulty, uncertainty, or useful remaining work is not blocked."
  )

  @impl DshBeam.Plugin
  def handle_dsh_tool_call(:get_goal, _args, state) do
    with {:ok, session} <- session(state) do
      goal = DshBeam.Goal.current(session)

      {:ok,
       JSON.encode!(%{
         "goal" => goal,
         "activation" => if(goal, do: DshBeam.Goal.Driver.armed_ctx(state.ctx), else: false)
       })}
    end
  end

  def handle_dsh_tool_call(:create_goal, %{"objective" => objective} = args, state) do
    with {:ok, session} <- session(state) do
      opts =
        if Map.has_key?(args, "max_goal_rounds"),
          do: [max_goal_rounds: args["max_goal_rounds"]],
          else: []

      case DshBeam.Goal.create(session, objective, opts) do
        {:ok, goal} ->
          DshBeam.Goal.Driver.arm_ctx(state.ctx)
          {:ok, JSON.encode!(%{"goal" => goal})}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def handle_dsh_tool_call(
        :update_goal,
        %{"goal_id" => id, "revision" => revision, "action" => action} = args,
        state
      ) do
    with {:ok, session} <- session(state) do
      case DshBeam.Goal.update(session, id, revision, action, update_opts(args)) do
        {:ok, goal} ->
          apply_activation(state, action)
          {:ok, JSON.encode!(%{"goal" => goal})}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # Mutations mirror the reference's activation rules: create/resume arm the
  # continuation driver; pause/complete/blocked disarm it (edit retains it).
  defp apply_activation(state, "resume"), do: DshBeam.Goal.Driver.arm_ctx(state.ctx)

  defp apply_activation(state, action) when action in ["pause", "complete", "blocked"],
    do: DshBeam.Goal.Driver.disarm_ctx(state.ctx)

  defp apply_activation(_state, _action), do: :ok

  defp update_opts(args) do
    []
    |> maybe_put(:objective, args["objective"])
    |> maybe_put(:max_goal_rounds, args["max_goal_rounds"])
    |> maybe_put(:blocked_reason, args["blocked_reason"])
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, _key, ""), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp session(state) do
    case DshBeam.Context.resolve(state.ctx) do
      {:active, %{session: session}} -> {:ok, session}
      _ -> {:error, :session_unavailable}
    end
  end
end
