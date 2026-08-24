defmodule DshBeam.Llm.Models do
  @moduledoc """
  The model roster — the reference's per-session `ModelDirectory`, seeded with
  the DeepSeek models. A group bundles a provider's models; a reasoning model
  carries a `reasoning` map with its effort levels and default effort (the
  reference advertises `off/low/high/max`; this PoC ships the three meaningful
  levels `low/high/max` and omits the `off`/thinking-disabled toggle).

  The roster is the data the composer model/effort seat (§4/§5 of
  `docs/reference-ui-port-spec.md`) renders; selection itself lives in the LLM
  capability (`DshBeam.Llm.Plugin` `:model` / `:reasoning_effort` settings).
  """

  @roster [
    %{
      id: "deepseek-official",
      name: "DeepSeek",
      models: [
        %{
          id: "deepseek-chat",
          name: "DeepSeek Chat",
          description: "General-purpose chat model.",
          reasoning: nil
        },
        %{
          id: "deepseek-reasoner",
          name: "DeepSeek Reasoner",
          description: "Reasoning model with adjustable effort.",
          reasoning: %{
            default_effort: "high",
            efforts: [
              %{id: "low", name: "Low", description: "Fastest, fewer reasoning tokens."},
              %{id: "high", name: "High", description: "Default, more thorough."},
              %{id: "max", name: "Max", description: "Most thorough reasoning."}
            ]
          }
        }
      ]
    }
  ]

  @typedoc "One provider group in the roster."
  @type group :: %{id: String.t(), name: String.t(), models: [model()]}

  @typedoc "One model in the roster."
  @type model :: %{
          id: String.t(),
          name: String.t(),
          description: String.t(),
          reasoning: reasoning() | nil
        }

  @typedoc "A reasoning model's effort vocabulary."
  @type reasoning :: %{
          default_effort: String.t(),
          efforts: [%{id: String.t(), name: String.t(), description: String.t()}]
        }

  @doc "The roster, provider-grouped."
  @spec groups() :: [group()]
  def groups, do: @roster

  @doc "All models, flattened across groups."
  @spec models() :: [model()]
  def models, do: Enum.flat_map(@roster, & &1.models)

  @doc "Look up a model by id (nil when unknown)."
  @spec find_model(String.t()) :: model() | nil
  def find_model(id) do
    Enum.find(models(), &(&1.id == id))
  end

  @doc """
  The reasoning vocabulary for a model id: `%{default_effort, efforts}`, or
  nil for a non-reasoning model.
  """
  @spec reasoning(String.t()) :: reasoning() | nil
  def reasoning(model_id) do
    case find_model(model_id) do
      %{reasoning: %{default_effort: default, efforts: efforts}} ->
        %{default_effort: default, efforts: efforts}

      _ ->
        nil
    end
  end
end
