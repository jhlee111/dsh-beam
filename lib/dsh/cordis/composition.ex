defmodule DshBeam.Composition do
  @moduledoc """
  A declarative composition (paper §5.2, Definition 74): entries declare id,
  plugin, config, and disabled; entries/1 projects them into the entry list
  DshBeam.Runtime consumes, so a composition module is the runtime's config file.
  """

  alias Spark.Builder.{Entity, Field, Section}

  use Spark.Dsl.Extension,
    sections: [
      Section.new(:entry,
        describe: "one plugin entry in this composition",
        top_level?: true,
        entities: [
          Entity.new(:entry, DshBeam.Composition.Entry,
            describe: "one plugin entry",
            args: [:id, :plugin],
            schema: [
              Field.new(:id, :atom, required: true, doc: "stable entry id"),
              Field.new(:plugin, {:behaviour, DshBeam.Plugin},
                required: true,
                doc: "plugin module"
              ),
              Field.new(:config, :keyword_list, default: [], doc: "plugin config"),
              Field.new(:disabled, :boolean,
                default: false,
                doc: "administratively off"
              )
            ],
            identifier: :id
          )
          |> Entity.build!()
        ]
      )
      |> Section.build!()
    ]

  use Spark.Dsl, default_extensions: [extensions: __MODULE__]

  defmodule Entry do
    @moduledoc false
    defstruct [:id, :plugin, :config, :disabled, :__identifier__, :__spark_metadata__]
  end

  @doc "The entry list of a composition module, feedable to DshBeam.Runtime."
  def entries(module) do
    module
    |> Spark.Dsl.Extension.get_entities([:entry])
    |> Enum.map(&Map.take(&1, [:id, :plugin, :config, :disabled]))
  end
end
