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

  Plugins implement mount/3 and may override the three handle_dsh_* hooks.
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

  @optional_callbacks handle_dsh_withdraw: 2, handle_dsh_activate: 2, handle_dsh_ready: 1

  @doc "The fiber's own lifecycle state (its :gen_statem state)."
  def fiber_state(pid), do: :gen_statem.call(pid, :__dsh_fiber_state__)

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

      def handle_event(:info, {:dsh_withdraw, _keys}, :unloading, data) do
        {:keep_state_and_data, data}
      end

      def handle_event(:info, {:dsh_withdraw, _keys}, :inactive, data) do
        {:keep_state_and_data, data}
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

      def handle_event(:info, {:EXIT, _pid, _reason}, _state, data) do
        # a linked resource (or the parent) exited: stop and let the context's
        # monitor safety net withdraw our contributions
        {:stop, :normal, data}
      end

      def handle_event(:info, _msg, _state, data), do: {:keep_state_and_data, data}

      @impl true
      def terminate(_reason, _state, data) do
        ctx = data.ctx

        if is_pid(ctx) and Process.alive?(ctx) do
          DshBeam.Context.unload(ctx, self())

          receive do
            {:dsh_unloaded, _owner} -> :ok
          after
            @dsh_unload_timeout -> :ok
          end
        end

        :ok
      end

      # Default mount: compile the need/provide declarations into the
      # mount/3 contract. Plugins with runtime work (starting resources)
      # override mount directly (the override carries @impl).
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

        {:ok, needs, provides, %{}}
      end

      def handle_dsh_withdraw(_keys, state), do: {:ok, state}
      def handle_dsh_activate(_view, state), do: {:ok, state}
      def handle_dsh_ready(state), do: {:ok, state}

      defoverridable mount: 2,
                     handle_dsh_withdraw: 2,
                     handle_dsh_activate: 2,
                     handle_dsh_ready: 1,
                     terminate: 3
    end
  end
end
