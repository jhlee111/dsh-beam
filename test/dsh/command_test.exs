defmodule DshBeam.CommandTest do
  use ExUnit.Case, async: true

  test "ships the command catalog in declaration order" do
    assert DshBeam.Command.names() == ["permission", "model", "goal", "clear", "help", "folders"]

    assert DshBeam.Command.find("permission").description =~ "permission preset"
    assert DshBeam.Command.find("model").hint == "<deepseek-chat|deepseek-reasoner>"
    assert DshBeam.Command.find("goal").description =~ "goal"
    assert DshBeam.Command.find("nope") == nil
  end

  test "parse/1 splits a slash command into name + args" do
    assert DshBeam.Command.parse("/permission read-only") == {:command, "permission", "read-only"}

    assert DshBeam.Command.parse("/model deepseek-reasoner") ==
             {:command, "model", "deepseek-reasoner"}

    assert DshBeam.Command.parse("/clear") == {:command, "clear", ""}

    assert DshBeam.Command.parse("/goal edit the plan") == {:command, "goal", "edit the plan"}
    assert DshBeam.Command.parse("/") == {:command, "", ""}
  end

  test "parse/1 passes non-command lines through" do
    assert DshBeam.Command.parse("just a normal message") ==
             {:not_command, "just a normal message"}
  end
end
