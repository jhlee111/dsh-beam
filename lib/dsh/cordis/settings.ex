defmodule DshBeam.Settings do
  @moduledoc """
  The typed settings store: per-plugin overrides validated against each
  plugin's DSL schema, layered over the declared defaults. The original
  harness's "settings file" — with credentials deliberately absent: a
  credential setting holds a DshBeam.Credential reference, never a literal
  key, so keys live outside this store.

  File persistence is future work; the design point here is the separation of
  (a) the declared schema, (b) the stored overrides, and (c) credentials.
  """

  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
  end

  @doc "Resolve one setting: the override, else the declared default."
  def get(store, plugin, name), do: GenServer.call(store, {:get, plugin, name})

  @doc "Override one setting, validated against the plugin's schema."
  def put(store, plugin, name, value), do: GenServer.call(store, {:put, plugin, name, value})

  @doc "Every resolved setting of one plugin (defaults + overrides)."
  def all(store, plugin), do: GenServer.call(store, {:all, plugin})

  @impl true
  def init(_opts), do: {:ok, %{overrides: %{}}}

  @impl true
  def handle_call({:get, plugin, name}, _from, state) do
    case schema(plugin, name) do
      nil ->
        {:reply, :not_found, state}

      setting ->
        {:reply, {:ok, resolve(state, plugin, name, setting.default)}, state}
    end
  end

  def handle_call({:put, plugin, name, value}, _from, state) do
    case schema(plugin, name) do
      nil ->
        {:reply, :not_found, state}

      setting ->
        if valid?(setting, value) do
          overrides =
            Map.update(state.overrides, plugin, %{name => value}, fn plugin_overrides ->
              Map.put(plugin_overrides, name, value)
            end)

          {:reply, :ok, %{state | overrides: overrides}}
        else
          {:reply, {:error, :invalid_value}, state}
        end
    end
  end

  def handle_call({:all, plugin}, _from, state) do
    resolved =
      DshBeam.Plugin.settings(plugin)
      |> Map.new(fn setting ->
        {setting.name, resolve(state, plugin, setting.name, setting.default)}
      end)

    {:reply, resolved, state}
  end

  defp resolve(state, plugin, name, default) do
    case Map.fetch(state.overrides, plugin) do
      {:ok, overrides} -> Map.get(overrides, name, default)
      :error -> default
    end
  end

  defp schema(plugin, name) do
    DshBeam.Plugin.settings(plugin) |> Enum.find(&(&1.name == name))
  end

  defp valid?(%{type: :integer}, value), do: is_integer(value)
  defp valid?(%{type: :float}, value), do: is_number(value)
  defp valid?(%{type: :boolean}, value), do: is_boolean(value)
  defp valid?(%{type: :string}, value), do: is_binary(value)
  defp valid?(%{type: :atom}, value), do: is_atom(value)

  defp valid?(%{type: :credential}, value) do
    match?({:env, name} when is_binary(name), value) or
      match?({:literal, key} when is_binary(key), value)
  end

  defp valid?(_setting, _value), do: false
end
