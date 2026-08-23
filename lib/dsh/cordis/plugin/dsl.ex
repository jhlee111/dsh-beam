defmodule DshBeam.Plugin.Dsl do
  @moduledoc """
  The declarative front of a plugin: need/provide sections compiled to the
  mount/3 contract (the paper's component declarations d and p, Definition
  44). Declarations are validated at compile time by Spark and introspectable
  at runtime — the substrate for a cordis_inspect-style catalog.
  """

  alias Spark.Builder.{Entity, Field, Section}

  defmodule Need do
    @moduledoc false
    defstruct [:key, :intercept, :__identifier__, :__spark_metadata__]
  end

  defmodule Provide do
    @moduledoc false
    defstruct [:key, :value, :via, :__identifier__, :__spark_metadata__]
  end

  defmodule Setting do
    @moduledoc false
    defstruct [:name, :type, :default, :doc, :__identifier__, :__spark_metadata__]
  end

  defmodule Tool do
    @moduledoc false
    defstruct [
      :name,
      :description,
      :parameters,
      :timeout_ms,
      :__identifier__,
      :__spark_metadata__
    ]
  end

  use Spark.Dsl.Extension,
    sections: [
      Section.new(:need,
        describe: "A dependency key this fiber resolves before activating",
        top_level?: true,
        entities: [
          Entity.new(:need, Need,
            describe: "one dependency declaration",
            args: [:key],
            schema: [
              Field.new(:key, :atom, required: true, doc: "the provided key"),
              Field.new(:intercept, :any,
                doc: "an {M, f, args} that wraps the resolved value for this fiber"
              )
            ],
            identifier: :key
          )
          |> Entity.build!()
        ]
      )
      |> Section.build!(),
      Section.new(:provide,
        describe: "A key this fiber provides",
        top_level?: true,
        entities: [
          Entity.new(:provide, Provide,
            describe: "one provision declaration",
            args: [:key],
            schema: [
              Field.new(:key, :atom, required: true, doc: "the provided key"),
              Field.new(:value, :any, doc: "a static value to provide"),
              Field.new(:via, {:mfa_or_fun, 0},
                doc: "an MFA or 0-arity function computing the value at mount"
              )
            ],
            identifier: :key
          )
          |> Entity.build!()
        ]
      )
      |> Section.build!(),
      Section.new(:setting,
        describe: "A typed configuration setting (the plugin inventory's schema)",
        top_level?: true,
        entities: [
          Entity.new(:setting, Setting,
            describe: "one typed setting with its default",
            args: [:name],
            schema: [
              Field.new(:name, :atom, required: true, doc: "the setting key"),
              Field.new(:type, :atom,
                required: true,
                doc: ":integer | :float | :boolean | :string | :credential"
              ),
              Field.new(:default, :any, required: true, doc: "the default value"),
              Field.new(:doc, :string, default: "", doc: "human description")
            ],
            identifier: :name
          )
          |> Entity.build!()
        ]
      )
      |> Section.build!(),
      Section.new(:tool,
        describe: "A model-callable tool this plugin provides (a tool is a plugin)",
        top_level?: true,
        entities: [
          Entity.new(:tool, Tool,
            describe: "one tool declaration",
            args: [:name],
            schema: [
              Field.new(:name, :atom, required: true, doc: "the tool name"),
              Field.new(:description, :string, required: true, doc: "what the tool does"),
              Field.new(:parameters, :any, default: %{}, doc: "JSON Schema of the arguments"),
              Field.new(:timeout_ms, {:or, [:integer, nil]},
                default: nil,
                doc: "cooperative per-call budget; the tool call is aborted after this many ms"
              )
            ],
            identifier: :name
          )
          |> Entity.build!()
        ]
      )
      |> Section.build!()
    ]

  use Spark.Dsl, default_extensions: [extensions: __MODULE__]
end
