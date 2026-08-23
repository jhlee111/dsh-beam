defmodule DshBeam.Plugin do
  @moduledoc """
  Everything in the harness is a plugin — and every plugin is a fiber: a
  :gen_statem process whose four states realize the paper's fiber lifecycle
  (§4.3): :inactive (waiting for dependencies), :reloading (activation in
  progress), :active (installed: committed view + effect accumulator), and
  :unloading (deactivation in progress, before the provider withdraws).

  ## Protocol

  - Registration: on start, the fiber registers its declarations with the
    context and enters :active or :inactive from the resolution.
  - Activation: the context sends {:dsh_activate, view}; the fiber passes
    through :reloading, runs handle_dsh_activate/2, and settles in :active.
  - Withdrawal: the context sends {:dsh_withdraw, keys} before removing a
    provider's binding. The fiber enters :unloading, runs
    handle_dsh_withdraw/2 — during which the binding is still readable — then
    acknowledges {:dsh_deactivated, pid, keys} and settles in :inactive. A
    deactivated fiber survives and can reactivate.
  - Termination: terminate/3 unloads the plugin from the context and waits
    briefly for the withdrawal to complete, so a provider's resources stay
    alive while its dependents finish their teardown.
  - Every transition reports {:dsh_fiber_state, pid, state} to the context,
    whose mirror drives the dependency graph; the fiber's own state is
    authoritative.

  Plugins implement mount/3 and may override the three handle_dsh_* hooks, plus
  two generic message hooks: handle_dsh_info/2 receives unclaimed :info
  messages (e.g. port data), handle_dsh_exit/3 receives linked-process exits
  (defaulting to a graceful stop).
  """

  @typedoc "The unified context pid."
  @type ctx :: pid()

  @callback mount(ctx(), keyword()) ::
              {:ok, deps :: [atom()], provides :: map(), extra :: term()}

  @callback handle_dsh_withdraw(keys :: [atom()], state :: DshBeam.Plugin.State.t()) ::
              {:ok, DshBeam.Plugin.State.t()}

  @callback handle_dsh_activate(view :: map(), state :: DshBeam.Plugin.State.t()) ::
              {:ok, DshBeam.Plugin.State.t()}

  @callback handle_dsh_ready(state :: DshBeam.Plugin.State.t()) ::
              {:ok, DshBeam.Plugin.State.t()}

  @callback handle_dsh_info(msg :: term(), state :: DshBeam.Plugin.State.t()) ::
              {:ok, DshBeam.Plugin.State.t()} | {:stop, term(), DshBeam.Plugin.State.t()}

  @callback handle_dsh_exit(
              from :: pid() | port(),
              reason :: term(),
              state :: DshBeam.Plugin.State.t()
            ) ::
              {:ok, DshBeam.Plugin.State.t()} | {:stop, term(), DshBeam.Plugin.State.t()}

  @callback handle_dsh_tool_call(name :: atom(), args :: map(), state :: DshBeam.Plugin.State.t()) ::
              {:ok, term()} | {:error, term()}

  @optional_callbacks handle_dsh_withdraw: 2,
                      handle_dsh_activate: 2,
                      handle_dsh_ready: 1,
                      handle_dsh_info: 2,
                      handle_dsh_exit: 3,
                      handle_dsh_tool_call: 3

  @doc "The fiber's own lifecycle state (its :gen_statem state)."
  def fiber_state(pid), do: :gen_statem.call(pid, :__dsh_fiber_state__)

  @doc """
  The module's declared tools (name/description/parameters), introspected
  from the Spark DSL — a tool is a plugin, and this is its model-facing schema.
  """
  def tools(mod) when is_atom(mod) do
    if Code.ensure_loaded?(mod) do
      try do
        Spark.Dsl.Extension.get_entities(mod, [:tool])
        |> Enum.map(fn tool ->
          %{name: tool.name, description: tool.description, parameters: tool.parameters}
        end)
      rescue
        _ -> []
      end
    else
      []
    end
  end

  @doc """
  The module's declared typed settings (name/type/default/doc), introspected
  from the Spark DSL — the schema a plugin-inventory/settings UI renders.
  """
  def settings(mod) when is_atom(mod) do
    if Code.ensure_loaded?(mod) do
      try do
        Spark.Dsl.Extension.get_entities(mod, [:setting])
        |> Enum.map(fn setting ->
          %{name: setting.name, type: setting.type, default: setting.default, doc: setting.doc}
        end)
      rescue
        _ -> []
      end
    else
      []
    end
  end

  # The case analyses on the generic hooks live here, behind a remote call,
  # so the type checker treats the dispatch result as dynamic: the default
  # hook bodies return a single shape, and narrowing a local call's case
  # against that shape would flag the other clause as never matching.
  @doc false
  def apply_exit_hook(result) do
    case result do
      {:ok, _data} -> {:keep_state_and_data, []}
      {:stop, stop_reason, data} -> {:stop, stop_reason, data}
    end
  end

  @doc false
  def apply_info_hook(result) do
    case result do
      {:ok, _data} -> {:keep_state_and_data, []}
      {:stop, stop_reason, data} -> {:stop, stop_reason, data}
    end
  end

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      @behaviour DshBeam.Plugin
      @behaviour :gen_statem

      # Declarative declarations: need/provide sections (Spark-validated).
      use DshBeam.Plugin.Dsl

      @dsh_unload_timeout Keyword.get(opts, :unload_timeout, 2000)

      def start_link(ctx, config) do
        :gen_statem.start_link(__MODULE__, {ctx, config}, [])
      end

      @impl true
      def callback_mode, do: :handle_event_function

      @impl true
      def init({ctx, config}) do
        Process.flag(:trap_exit, true)
        id = Keyword.fetch!(config, :id)
        {:ok, deps, provides, extra} = mount(ctx, config)

        # Registration is synchronous: start_link returns only after the fiber
        # exists in the context, so callers never observe a half-started fiber.
        case DshBeam.Context.register(ctx, id: id, deps: deps, provides: provides) do
          {:ok, fiber_state, view} ->
            data = %DshBeam.Plugin.State{
              ctx: ctx,
              id: id,
              fiber_state: fiber_state,
              view: view,
              config: config,
              extra: extra
            }

            send(ctx, {:dsh_fiber_state, self(), fiber_state})
            {:ok, data} = handle_dsh_ready(data)
            {:ok, fiber_state, data}

          {:error, reason} ->
            {:stop, reason}
        end
      end

      @impl true
      def handle_event(:info, {:dsh_activate, view}, :inactive, data) do
        {:next_state, :reloading, %{data | view: view},
         {:next_event, :internal, :finish_activate}}
      end

      def handle_event(:info, {:dsh_activate, view}, :unloading, data) do
        {:next_state, :reloading, %{data | view: view},
         {:next_event, :internal, :finish_activate}}
      end

      def handle_event(:info, {:dsh_activate, view}, :reloading, data) do
        # re-commit mid-activation: the finish event reads the updated view
        {:keep_state, %{data | view: view}}
      end

      def handle_event(:info, {:dsh_activate, view}, :active, data) do
        # the committed view changed in place: re-commit and stay active
        {:ok, data} = handle_dsh_activate(view, %{data | view: view})
        {:keep_state, data}
      end

      def handle_event(:internal, :finish_activate, :reloading, data) do
        {:ok, data} = handle_dsh_activate(data.view, data)
        data = %{data | fiber_state: :active}
        send(data.ctx, {:dsh_fiber_state, self(), :active})
        {:next_state, :active, data}
      end

      def handle_event(:info, {:dsh_withdraw, keys}, :active, data) do
        {:next_state, :unloading, data, {:next_event, :internal, {:finish_withdraw, keys}}}
      end

      def handle_event(:info, {:dsh_withdraw, keys}, :reloading, data) do
        {:next_state, :unloading, data, {:next_event, :internal, {:finish_withdraw, keys}}}
      end

      def handle_event(:info, {:dsh_withdraw, _keys}, :unloading, _data) do
        {:keep_state_and_data, []}
      end

      def handle_event(:info, {:dsh_withdraw, _keys}, :inactive, _data) do
        {:keep_state_and_data, []}
      end

      def handle_event(:internal, {:finish_withdraw, keys}, :unloading, data) do
        {:ok, data} = handle_dsh_withdraw(keys, %{data | fiber_state: :unloading})
        data = %{data | fiber_state: :inactive}
        send(data.ctx, {:dsh_deactivated, self(), keys})
        send(data.ctx, {:dsh_fiber_state, self(), :inactive})
        {:next_state, :inactive, data}
      end

      def handle_event({:call, from}, :__dsh_fiber_state__, _state, data) do
        {:keep_state_and_data, [{:reply, from, data.fiber_state}]}
      end

      def handle_event({:call, from}, {:tool_call, name, args}, _state, data) do
        # a plugin may override handle_dsh_tool_call with only its own
        # clauses; a partial implementation is a FunctionClauseError, which
        # is the "tool not implemented" case, not a fiber crash
        result =
          try do
            handle_dsh_tool_call(name, args, data)
          rescue
            FunctionClauseError -> {:error, :not_implemented}
          end

        {:keep_state_and_data, [{:reply, from, result}]}
      end

      def handle_event(:info, {:EXIT, from, reason}, _state, data) do
        # a linked resource (or the parent) exited: by default stop and let
        # the context's monitor safety net withdraw our contributions
        DshBeam.Plugin.apply_exit_hook(handle_dsh_exit(from, reason, data))
      end

      def handle_event(:info, msg, _state, data) do
        DshBeam.Plugin.apply_info_hook(handle_dsh_info(msg, data))
      end

      @impl true
      def terminate(_reason, _state, data) do
        ctx = data.ctx

        if is_pid(ctx) and Process.alive?(ctx) do
          # the context may die between the alive? check and the call (the
          # runtime tears it down on the same exit cascade): a dead context
          # needs no unload, so swallow the race
          try do
            DshBeam.Context.unload(ctx, self())

            receive do
              {:dsh_unloaded, _owner} -> :ok
            after
              @dsh_unload_timeout -> :ok
            end
          catch
            :exit, _reason -> :ok
          end
        end

        :ok
      end

      # Default mount: compile the need/provide/tool declarations into the
      # mount/3 contract. Plugins with runtime work (starting resources)
      # override mount directly (the override carries @impl). A tool is a
      # capability: each declared tool name is provided as this fiber.
      def mount(_ctx, _config) do
        needs = Spark.Dsl.Extension.get_entities(__MODULE__, [:need]) |> Enum.map(& &1.key)

        provides =
          Spark.Dsl.Extension.get_entities(__MODULE__, [:provide])
          |> Enum.map(fn provide ->
            value =
              case {provide.value, provide.via} do
                {nil, nil} ->
                  raise ArgumentError, "provide #{inspect(provide.key)} requires :value or :via"

                {value, nil} ->
                  value

                {nil, via} when is_function(via, 0) ->
                  via.()

                {nil, {m, f, a}} ->
                  apply(m, f, a)
              end

            {provide.key, value}
          end)
          |> Map.new()

        tool_provides =
          Spark.Dsl.Extension.get_entities(__MODULE__, [:tool])
          |> Map.new(&{&1.name, self()})

        {:ok, needs, Map.merge(provides, tool_provides), %{}}
      end

      def handle_dsh_withdraw(_keys, state), do: {:ok, state}
      def handle_dsh_activate(_view, state), do: {:ok, state}
      def handle_dsh_ready(state), do: {:ok, state}
      def handle_dsh_tool_call(_name, _args, _state), do: {:error, :not_implemented}

      # The specs widen the default returns to the callback's full union so
      # the type checker accepts the {:ok, _} / {:stop, _, _} case clauses
      # above even for plugins that never override these hooks.
      @spec handle_dsh_info(term(), DshBeam.Plugin.State.t()) ::
              {:ok, DshBeam.Plugin.State.t()} | {:stop, term(), DshBeam.Plugin.State.t()}
      def handle_dsh_info(_msg, state), do: {:ok, state}

      @spec handle_dsh_exit(term(), term(), DshBeam.Plugin.State.t()) ::
              {:ok, DshBeam.Plugin.State.t()} | {:stop, term(), DshBeam.Plugin.State.t()}
      def handle_dsh_exit(_from, _reason, state), do: {:stop, :normal, state}

      defoverridable mount: 2,
                     handle_dsh_withdraw: 2,
                     handle_dsh_activate: 2,
                     handle_dsh_ready: 1,
                     handle_dsh_info: 2,
                     handle_dsh_exit: 3,
                     handle_dsh_tool_call: 3,
                     terminate: 3
    end
  end
end
