defmodule DshBeam.SystemPromptTest do
  use ExUnit.Case, async: true

  test "render includes the harness identity and the default persona" do
    prompt = DshBeam.SystemPrompt.render()

    assert prompt =~ "dsh-beam"
    assert prompt =~ "plugin-based harness"
    assert prompt =~ "You are a helpful agent."
  end

  test "a plugin's prompt_section is assembled into the prompt" do
    prompt = DshBeam.SystemPrompt.render()

    # DshBeam.Tool.Plugin registers a self_modification section (order 100)
    assert prompt =~ "define_plugin"
    assert prompt =~ "save_plugin"
    assert prompt =~ "redefine_plugin"
    assert prompt =~ "~/.dsh/plugins"
  end
end
