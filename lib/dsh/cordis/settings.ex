defmodule DshBeam.Settings do
  @moduledoc """
  The typed settings store: per-plugin overrides validated against each
  plugin's DSL schema, layered over the declared defaults — the original
  harness's "settings file".

  Overrides can be persisted to disk (a JSON file) when a `:path` is given:
  the store loads it on start and rewrites it on every `put/4`, so a saved
  setting (e.g. the LLM model + credential) survives a restart. Without a
  `:path` the store is in-memory (the default, and what tests use), so a
  memory-only store never touches the filesystem.

  A credential setting holds a `DshBeam.Credential` reference — `{:env, name}`
  by default — or a `{:literal, key}`; both are persisted as tagged JSON. The
  literal form stores the key in the settings file, the tradeoff the original
  harness's Models surface accepts; the env-reference form keeps the key out of
  the store.
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

  @doc "The persisted-override file this store uses, or nil when in-memory."
  def path(store), do: GenServer.call(store, :path)

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :path)
    {:ok, %{overrides: load(path), path: path}}
  end

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

          state = %{state | overrides: overrides}
          {:reply, :ok, persist(state)}
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

  def handle_call(:path, _from, state), do: {:reply, state.path, state}

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

  # -- persistence --

  defp load(nil), do: %{}

  defp load(path) when is_binary(path) do
    with true <- File.exists?(path),
         {:ok, json} <- File.read(path),
         {:ok, decoded} <- JSON.decode(json),
         true <- is_map(decoded) do
      decode_overrides(decoded)
    else
      _ -> %{}
    end
  end

  defp persist(%{path: nil} = state), do: state

  defp persist(%{path: path, overrides: overrides} = state) when is_binary(path) do
    File.mkdir_p!(Path.dirname(path))

    encoded =
      Map.new(overrides, fn {plugin, per_plugin} ->
        {Atom.to_string(plugin),
         Map.new(per_plugin, fn {k, v} -> {Atom.to_string(k), encode(v)} end)}
      end)

    File.write!(path, JSON.encode!(Map.put(%{}, :plugins, encoded)))
    state
  end

  # {plugin_module => %{name => value}}, persisted as %{"plugins" => %{...}}
  # Names/values are decoded with String.to_atom because the store loads before
  # the plugins do, so the setting-name atoms may not exist yet. The file is a
  # local, user-owned settings file — not untrusted input.
  defp decode_overrides(%{"plugins" => plugins}) when is_map(plugins) do
    Map.new(plugins, fn {plugin_str, per_plugin} ->
      {decode_plugin(plugin_str),
       Map.new(per_plugin, fn {name_str, value} ->
         {String.to_atom(name_str), decode(value)}
       end)}
    end)
  end

  defp decode_overrides(_), do: %{}

  defp decode_plugin(str) do
    Module.concat(String.split(str, "."))
  rescue
    _ -> String.to_atom(str)
  end

  # non-atom values encode directly; atoms and credentials carry a tag
  defp encode({:env, name}), do: %{"tag" => "env", "value" => name}
  defp encode({:literal, key}), do: %{"tag" => "literal", "value" => key}
  defp encode(v) when is_atom(v), do: %{"tag" => "atom", "value" => Atom.to_string(v)}
  defp encode(v), do: v

  defp decode(%{"tag" => "env", "value" => v}), do: {:env, v}
  defp decode(%{"tag" => "literal", "value" => v}), do: {:literal, v}
  defp decode(%{"tag" => "atom", "value" => v}), do: String.to_existing_atom(v)
  defp decode(v), do: v
end
