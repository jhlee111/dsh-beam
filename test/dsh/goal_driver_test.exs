defmodule DshBeam.Goal.DriverTest do
  use ExUnit.Case, async: false

  defp session_entry,
    do: %{id: :session, plugin: DshBeam.Session.Plugin, config: [], disabled: false}

  defp llm_entry, do: %{id: :llm, plugin: DshBeam.Llm.Plugin, config: [], disabled: false}

  defp adapter_entry,
    do: %{id: :adapter, plugin: GoalDriverStubLlm, config: [], disabled: false}

  defp loop_entry, do: %{id: :loop, plugin: DshBeam.Agent.Loop, config: [], disabled: false}

  defp driver_entry, do: %{id: :driver, plugin: DshBeam.Goal.Driver, config: [], disabled: false}

  defp mount do
    {:ok, runtime} =
      DshBeam.Runtime.start_link(
        [session_entry(), llm_entry(), adapter_entry(), loop_entry(), driver_entry()],
        []
      )

    ctx = DshBeam.Runtime.context(runtime)
    {:ok, session} = DshBeam.Context.get(ctx, :session)
    {:ok, driver} = DshBeam.Context.get(ctx, :goal_driver)
    {session, driver}
  end

  test "arm/disarm/armed? toggle activation" do
    {_session, driver} = mount()

    refute DshBeam.Goal.Driver.armed?(driver)
    assert :ok = DshBeam.Goal.Driver.arm(driver)
    assert DshBeam.Goal.Driver.armed?(driver)
    assert :ok = DshBeam.Goal.Driver.disarm(driver)
    refute DshBeam.Goal.Driver.armed?(driver)
  end

  test "run_rounds is refused while disarmed" do
    {_session, driver} = mount()
    assert {:error, :not_armed} = DshBeam.Goal.Driver.run_rounds(driver)
  end

  test "run_rounds reports no_goal when armed with no goal" do
    {_session, driver} = mount()
    :ok = DshBeam.Goal.Driver.arm(driver)
    assert {:ok, :no_goal} = DshBeam.Goal.Driver.run_rounds(driver)
  end

  test "run_rounds stops at the round cap" do
    {session, driver} = mount()
    :ok = DshBeam.Goal.Driver.arm(driver)

    assert {:ok, goal} = DshBeam.Goal.create(session, "work", max_goal_rounds: 1)
    assert {:ok, _seq} = DshBeam.Goal.round(session, goal)

    assert {:ok, :round_cap_reached} = DshBeam.Goal.Driver.run_rounds(driver)
  end

  test "run_rounds stops immediately on a non-active goal" do
    {session, driver} = mount()
    :ok = DshBeam.Goal.Driver.arm(driver)

    assert {:ok, goal} = DshBeam.Goal.create(session, "work")
    assert {:ok, _} = DshBeam.Goal.update(session, goal["id"], 1, "pause")

    assert {:ok, "paused"} = DshBeam.Goal.Driver.run_rounds(driver)
  end
end

defmodule GoalDriverStubLlm do
  @moduledoc false
  use DshBeam.Llm.Adapter

  @impl true
  def complete(_config, _messages, _opts) do
    {:ok, %{content: "answer", reasoning: nil, tool_calls: [], finish_reason: :stop, usage: nil}}
  end
end
