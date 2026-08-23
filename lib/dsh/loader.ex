defmodule DshBeam.Loader do
  @moduledoc """
  Declarative composition (paper §5.2): a desired configuration is an ordered
  list of entries; reconciliation diffs the mounted entries against it and
  returns the least disruptive change set.
  """

  @typedoc "One configuration entry: a fiber to mount."
  @type entry :: %{
          id: term(),
          plugin: module(),
          config: keyword(),
          disabled: boolean()
        }

  @typedoc "The desired configuration."
  @type config :: [entry()]

  @doc """
  Diff mounted entries (id => entry) against the desired configuration.

  Entries are compared structurally; a changed entry is reported as restart.
  """
  @spec diff(%{optional(term()) => entry()}, config()) :: %{
          start: config(),
          stop: [term()],
          restart: config()
        }
  def diff(current, desired) do
    desired_by_id = Map.new(desired, &{&1.id, &1})
    current = Map.new(current, fn {id, entry} -> {id, normalize(entry)} end)

    start = Enum.filter(desired, &(not Map.has_key?(current, &1.id)))

    stop =
      for {id, _entry} <- current, not Map.has_key?(desired_by_id, id), do: id

    restart =
      for entry <- desired,
          mounted = Map.get(current, entry.id),
          mounted != nil and mounted != normalize(entry),
          do: entry

    %{start: start, stop: stop, restart: restart}
  end

  # Keyword order must not affect equality: normalize configs to maps.
  defp normalize(entry), do: %{entry | config: Map.new(entry.config)}
end
