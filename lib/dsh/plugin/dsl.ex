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
    defstruct [:key, :__identifier__, :__spark_metadata__]
  end

  defmodule Provide do
    @moduledoc false
    defstruct [:key, :value, :via, :__identifier__, :__spark_metadata__]
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
            schema: [Field.new(:key, :atom, required: true, doc: "the provided key")],
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
      |> Section.build!()
    ]

  use Spark.Dsl, default_extensions: [extensions: __MODULE__]
end
