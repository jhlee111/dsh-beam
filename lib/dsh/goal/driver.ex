defmodule DshBeam.Goal.Driver do
  @moduledoc """
  The same-session goal continuation driver — the reference's
  `dsh-goal-round-driver`, on the BEAM.

  Turns an active, armed goal into sequential goal rounds: while the goal is
  `active`, armed, and under its round cap, `run_rounds/2` marks the next round
  and drives one agent-loop turn per round until the model reports `complete` /
  `blocked`, a human pauses/clears the goal, or the cap is reached.

  Activation (arming) is process-local and never persisted: it lives in this
  fiber's state. A fresh mount and `disarm/1` both start disarmed, so a resumed
  session never auto-continues until a human resumes the goal (which the model
  then `arm`s via `run_rounds` on an explicit continue).
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
    {:keep_state_and_data, [{:reply, from, do_run_rounds(data, token)}]}
  end

  # -- continuation loop --

  defp do_run_rounds(data, token) do
    with true <- Map.get(data.extra, :armed, false),
         {:active, %{session: session, loop: loop}} <- DshBeam.Context.resolve(data.ctx) do
      run_rounds_loop(session, loop, token)
    else
      _ -> {:error, :not_armed}
    end
  end

  defp run_rounds_loop(session, loop, token) do
    case DshBeam.Goal.current(session) do
      nil ->
        {:ok, :no_goal}

      %{"phase" => phase} when phase != "active" ->
        {:ok, phase}

      goal ->
        if goal["rounds_started"] >= goal["max_goal_rounds"] do
          {:ok, :round_cap_reached}
        else
          {:ok, _seq} = DshBeam.Goal.round(session, goal)
          goal = DshBeam.Goal.current(session)

          case DshBeam.Agent.Loop.run_trace(loop, round_prompt(goal), token) do
            {:ok, _answer, _trace} ->
              settle(session, loop, token)

            {:error, :stopped, _trace} ->
              {:error, :cancelled}

            {:error, reason} ->
              {:error, reason}
          end
        end
    end
  end

  # After one successful round, look at the durable goal phase: an active goal
  # continues; anything else (complete/paused/blocked/cleared) stops.
  defp settle(session, loop, token) do
    case DshBeam.Goal.current(session) do
      %{"phase" => "active"} -> run_rounds_loop(session, loop, token)
      %{"phase" => phase} -> {:ok, phase}
      nil -> {:ok, :cleared}
    end
  end

  defp round_prompt(goal) do
    """
    <goal_round>
    You are continuing the active goal. Objective: #{inspect(goal["objective"])}.
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
