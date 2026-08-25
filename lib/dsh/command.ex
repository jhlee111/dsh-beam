defmodule DshBeam.Command do
  @moduledoc """
  Slash-command catalog — the reference's host `command.list` directory, on the
  BEAM. A command has a name, a description (the menu row), and an argument
  hint (the ghost text after the claim token). `parse/1` turns a submitted
  line into `{name, args}`; `run/2` is owned by the console (it needs the
  session/llm/runtime context), while this module stays the pure, testable
  catalog the menu and the dispatcher both read.

  The seeded catalog maps to dsh-beam reality; `/plan`, `/compact`, `/retry`,
  `/fork` are reference commands that have no dsh-beam substrate yet and are
  intentionally absent.
  """

  @catalog %{
    "permission" => %{
      description: "Switch the permission preset",
      hint: "<read-only|workspace-write|danger-full-access>"
    },
    "model" => %{
      description: "Select the model for this conversation",
      hint: "<deepseek-chat|deepseek-reasoner>"
    },
    "goal" => %{
      description: "Manage the session goal",
      hint: "<objective|edit <objective>|pause|resume|clear>"
    },
    "clear" => %{description: "Clear the conversation", hint: ""},
    "help" => %{description: "List available commands", hint: ""}
  }

  @typedoc "One command descriptor (name-keyed)."
  @type descriptor :: %{description: String.t(), hint: String.t()}

  @typedoc "A parsed submission: {:command, name, args} or {:not_command, line}."
  @type parsed :: {:command, String.t(), String.t()} | {:not_command, String.t()}

  @doc "The seeded command catalog."
  @spec catalog() :: %{String.t() => descriptor()}
  def catalog, do: @catalog

  # Declaration order is the menu order (like the permission preset order).
  @names ["permission", "model", "goal", "clear", "help"]

  @doc "The command names, in declaration (menu) order."
  @spec names() :: [String.t()]
  def names, do: @names

  @doc "Look up a command by name (nil when unknown)."
  @spec find(String.t()) :: descriptor() | nil
  def find(name), do: Map.get(@catalog, name)

  @doc """
  Parse a submitted line: a `/name args` prefix yields `{:command, name, args}`
  (the first whitespace-delimited token is the command, the rest is its
  argument string); anything else is `{:not_command, line}`.
  """
  @spec parse(String.t()) :: parsed()
  def parse("/" <> rest) do
    case String.split(String.trim(rest), " ", trim: true) do
      [] ->
        {:command, "", ""}

      [name | args] ->
        {:command, name, Enum.join(args, " ")}
    end
  end

  def parse(line), do: {:not_command, line}
end
