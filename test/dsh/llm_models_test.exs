defmodule DshBeam.Llm.ModelsTest do
  use ExUnit.Case, async: true

  test "ships the DeepSeek group with a chat and a reasoner model" do
    assert [group] = DshBeam.Llm.Models.groups()
    assert group.id == "deepseek-official"
    assert group.name == "DeepSeek"
    assert Enum.map(group.models, & &1.id) == ["deepseek-chat", "deepseek-reasoner"]
  end

  test "models/0 flattens across groups" do
    assert Enum.map(DshBeam.Llm.Models.models(), & &1.id) == [
             "deepseek-chat",
             "deepseek-reasoner"
           ]
  end

  test "reasoning/1 returns nil for the chat model and a vocabulary for the reasoner" do
    assert DshBeam.Llm.Models.reasoning("deepseek-chat") == nil
    assert DshBeam.Llm.Models.reasoning("unknown") == nil

    assert %{default_effort: "high", efforts: efforts} =
             DshBeam.Llm.Models.reasoning("deepseek-reasoner")

    assert Enum.map(efforts, & &1.id) == ["low", "high", "max"]
    assert Enum.map(efforts, & &1.name) == ["Low", "High", "Max"]
  end

  test "find_model/1 resolves by id" do
    assert %{id: "deepseek-chat"} = DshBeam.Llm.Models.find_model("deepseek-chat")
    assert DshBeam.Llm.Models.find_model("nope") == nil
  end
end
