defmodule DshBeam.Goal.Driver do
  @moduledoc """
  The same-session goal continuation driver — the reference's
  `dsh-goal-round-driver`, on the BEAM.

  Turns an active, armed goal into sequential goal rounds: while the goal is
  `active`, armed, and under its round cap, `run_rounds/2` admits the next round
  and drives one agent-loop turn per round until the model reports `complete` /
  `blocked`, a human pauses/clears the goal, or the cap is reached.

  Activation (arming) is process-local and never persisted: it lives in this
  fiber's state. A fresh mount and `disarm/1` both start disarmed, so a resumed
  session never auto-continues until a human resumes the goal. Cancellation
  pauses the goal and disarms so it cannot auto-restart.
  """

  use DshBeam.Plugin

  @impl DshBeam.Plugin
  def mount(_ctx, _opts) do
    {:ok, [:session, :loop], %{goal_driver: self()}, %{armed: false}}
  end

  @doc "Arm continuation for the driver's current process-local state."
  def arm(driver), do: :gen_statem.call(driver, :arm)

  @doc "Disarm continuation (removes process-local authority without a durable mutation)."
  def disarm(driver), do: :gen_statem.call(driver, :disarm)

  @doc "Whether continuation is currently armed."
  def armed?(driver), do: :gen_statem.call(driver, :armed?)

  @doc "Arm continuation if `:goal_driver` is mounted; no-op otherwise."
  def arm_ctx(ctx) do
    case DshBeam.Context.get(ctx, :goal_driver) do
      {:ok, driver} -> arm(driver)
      _ -> :ok
    end
  end

  @doc "Disarm continuation if `:goal_driver` is mounted; no-op otherwise."
  def disarm_ctx(ctx) do
    case DshBeam.Context.get(ctx, :goal_driver) do
      {:ok, driver} -> disarm(driver)
      _ -> :ok
    end
  end

  @doc "Whether continuation is armed, or false when the driver is absent."
  def armed_ctx(ctx) do
    case DshBeam.Context.get(ctx, :goal_driver) do
      {:ok, driver} -> armed?(driver)
      _ -> false
    end
  end

  @doc """
  Run goal rounds to completion/stop. Blocks the driver fiber (like the loop's
  run_trace); call it from a Task with a per-run cancellation token.
  Returns `{:ok, stop_reason}` or `{:error, reason}`.
  """
  def run_rounds(driver, token \\ nil), do: :gen_statem.call(driver, {:run_rounds, token})

  @impl true
  def handle_event({:call, from}, :arm, _state, data) do
    {:keep_state, put_armed(data, true), [{:reply, from, :ok}]}
  end

  def handle_event({:call, from}, :disarm, _state, data) do
    {:keep_state, put_armed(data, false), [{:reply, from, :ok}]}
  end

  def handle_event({:call, from}, :armed?, _state, data) do
    {:keep_state_and_data, [{:reply, from, Map.get(data.extra, :armed, false)}]}
  end

  def handle_event({:call, from}, {:run_rounds, token}, _state, data) do
    {data, result} = do_run_rounds(data, token)
    {:keep_state, data, [{:reply, from, result}]}
  end

  # -- continuation loop --

  defp do_run_rounds(data, token) do
    with true <- Map.get(data.extra, :armed, false),
         {:active, %{session: session, loop: loop}} <- DshBeam.Context.resolve(data.ctx) do
      loop_rounds(session, loop, token, data)
    else
      _ -> {data, {:error, :not_armed}}
    end
  end

  defp loop_rounds(session, loop, token, data) do
    case DshBeam.Goal.current(session) do
      nil ->
        {data, {:ok, :no_goal}}

      %{"phase" => phase} when phase != "active" ->
        {data, {:ok, phase}}

      goal ->
        if goal["rounds_started"] >= goal["max_goal_rounds"] do
          {data, {:ok, :round_cap_reached}}
        else
          case DshBeam.Goal.round(session, goal) do
            {:error, reason} ->
              {data, {:error, reason}}

            {:ok, _seq} ->
              goal = DshBeam.Goal.current(session)

              case DshBeam.Agent.Loop.run_trace(loop, round_prompt(goal), token) do
                {:ok, _answer, _trace} ->
                  settle(session, loop, token, data)

                {:error, :stopped, _trace} ->
                  pause_goal(session)
                  {put_armed(data, false), {:error, :cancelled}}

                {:error, reason} ->
                  {put_armed(data, false), {:error, reason}}
              end
          end
        end
    end
  end

  # After one successful round, look at the durable goal phase: an active goal
  # continues; anything else (complete/paused/blocked/cleared) stops.
  defp settle(session, loop, token, data) do
    case DshBeam.Goal.current(session) do
      %{"phase" => "active"} -> loop_rounds(session, loop, token, data)
      %{"phase" => phase} -> {data, {:ok, phase}}
      nil -> {data, {:ok, :cleared}}
    end
  end

  # Cancellation must not auto-restart: pause the durable goal so a later
  # run_rounds stops at the non-active phase (explicit resume is required).
  defp pause_goal(session) do
    case DshBeam.Goal.current(session) do
      %{"phase" => "active", "id" => id, "revision" => revision} ->
        DshBeam.Goal.update(session, id, revision, "pause")

      _ ->
        :ok
    end
  end

  defp round_prompt(goal) do
    """
    <goal_round>
    You are continuing the active goal. Objective: #{goal["objective"]}.
    Round #{goal["rounds_started"]}/#{goal["max_goal_rounds"]}.

    Make concrete progress using the available tools. When the objective is
    actually achieved, call update_goal with action "complete" and the exact
    goal_id/revision from get_goal. When the same blocking condition persists
    across rounds, call update_goal with action "blocked" and a concrete
    blocked_reason. Otherwise keep working and leave the goal active.
    </goal_round>
    """
  end

  defp put_armed(data, armed), do: %{data | extra: Map.put(data.extra, :armed, armed)}
end
