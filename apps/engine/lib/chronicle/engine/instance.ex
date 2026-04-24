defmodule Chronicle.Engine.Instance do
  @moduledoc """
  GenServer per workflow instance (ProcessInstanceV2 equivalent).
  Each running BPMN process instance is a separate GenServer.
  """
  use GenServer, restart: :temporary

  require Logger

  alias Chronicle.Engine.{Token, PersistentData}
  alias Chronicle.Engine.Diagrams.Definition
  alias Chronicle.Engine.Instance.{TokenState, EventReplayer, WaitRegistry, Migration}

  @type state :: %{
    id: String.t(),
    business_key: String.t(),
    tenant_id: String.t(),
    definition: Definition.t(),
    instance_state: :active | :simulating | :waiting | :completed | :terminated,
    tokens: %{non_neg_integer() => Token.t()},
    active_tokens: MapSet.t(),
    waiting_tokens: MapSet.t(),
    completed_tokens: MapSet.t(),
    token_families: MapSet.t(),
    joining_list: map(),
    message_waits: map(),
    signal_waits: map(),
    message_boundaries: map(),
    signal_boundaries: map(),
    call_wait_list: map(),
    external_tasks: map(),
    script_waits: map(),
    parent_id: String.t() | nil,
    parent_business_key: String.t() | nil,
    root_id: String.t() | nil,
    root_business_key: String.t() | nil,
    pin_state: :not_pinned | :pinned | :force_pinned,
    pin_reason: atom(),
    next_token_id: non_neg_integer(),
    timer_refs: map(),
    persistent_events: [term()],
    last_persisted_index: non_neg_integer()
  }

  # --- Public API ---

  def start_link({definition, params}) do
    id = Map.get(params, :id, UUID.uuid4())
    tenant_id = Map.get(params, :tenant_id, "00000000-0000-0000-0000-000000000000")

    GenServer.start_link(__MODULE__, {definition, params},
      name: via(tenant_id, id)
    )
  end

  def start_link({:restore, instance_id, tenant_id, events}) do
    GenServer.start_link(__MODULE__, {:restore, instance_id, tenant_id, events},
      name: via(tenant_id, instance_id)
    )
  end

  def send_message(pid, message_name, payload \\ %{}) do
    GenServer.cast(pid, {:message, message_name, payload})
  end

  def send_signal(pid, signal_name) do
    GenServer.cast(pid, {:signal, signal_name})
  end

  def complete_external_task(pid, task_id, payload, result) do
    GenServer.cast(pid, {:external_task_complete, task_id, payload, result})
  end

  def error_external_task(pid, task_id, error, retry?, backoff_ms) do
    GenServer.cast(pid, {:external_task_error, task_id, error, retry?, backoff_ms})
  end

  def terminate_instance(pid, reason) do
    GenServer.cast(pid, {:terminate, reason})
  end

  def force_pin(pid), do: GenServer.cast(pid, :force_pin)
  def remove_force_pin(pid), do: GenServer.cast(pid, :remove_force_pin)

  def inspect_instance(pid) do
    GenServer.call(pid, :inspect)
  end

  def get_state(pid) do
    GenServer.call(pid, :get_state)
  end

  def migrate(pid, new_definition, node_mappings \\ %{}) do
    GenServer.call(pid, {:migrate, new_definition, node_mappings}, 30_000)
  end

  # --- Registry ---

  defp via(tenant_id, instance_id) do
    {:via, Registry, {:instances, {tenant_id, instance_id}}}
  end

  def lookup(tenant_id, instance_id) do
    case Registry.lookup(:instances, {tenant_id, instance_id}) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end

  # --- GenServer Callbacks ---

  @impl true
  def init({definition, params}) do
    id = Map.get(params, :id, UUID.uuid4())
    business_key = Map.get(params, :business_key, UUID.uuid4())
    tenant_id = Map.get(params, :tenant_id, "00000000-0000-0000-0000-000000000000")
    start_params = Map.get(params, :start_parameters, %{})

    state = Map.merge(TokenState.base_state(), %{
      id: id,
      business_key: business_key,
      tenant_id: tenant_id,
      definition: definition,
      instance_state: :active,
      token_families: MapSet.new([0]),
      parent_id: Map.get(params, :parent_id),
      parent_business_key: Map.get(params, :parent_business_key),
      root_id: Map.get(params, :root_id, id),
      root_business_key: Map.get(params, :root_business_key, business_key),
      start_parameters: start_params,
      start_node_id: Map.get(params, :start_node_id)
    })

    # Emit start persistent data
    start_data = %PersistentData.ProcessInstanceStart{
      process_instance_id: id,
      business_key: business_key,
      tenant: tenant_id,
      parent_id: state.parent_id,
      parent_business_key: state.parent_business_key,
      root_id: state.root_id,
      root_business_key: state.root_business_key,
      process_name: definition.name,
      process_version: definition.version,
      start_node_id: state.start_node_id,
      started_by_engine: Map.get(params, :started_by_engine, false),
      start_parameters: start_params
    }

    state = append_event(state, start_data)

    # Persist the initial ProcessInstanceStart event synchronously so that
    # the active row is created before we begin processing. A crash between
    # here and the first waiting transition must still be recoverable.
    case Chronicle.Persistence.EventStore.create(id, start_data) do
      {:ok, _} ->
        state = %{state | last_persisted_index: length(state.persistent_events)}

        # Broadcast start event
        Phoenix.PubSub.broadcast(Chronicle.PubSub, "engine:events",
          {:process_instance_started, id, business_key, tenant_id, start_data})

        {:ok, state, {:continue, :start_initial_token}}

      {:error, reason} ->
        Logger.error("Instance #{id}: Failed to persist start event: #{inspect(reason)}")
        {:stop, {:persist_start_failed, reason}}
    end
  end

  def init({:restore, instance_id, tenant_id, events}) do
    state = Map.merge(TokenState.base_state(), %{
      id: instance_id,
      tenant_id: tenant_id,
      instance_state: :simulating,
      persistent_events: events,
      last_persisted_index: length(events)
    })

    {:ok, state, {:continue, {:restore, events}}}
  end

  @impl true
  def handle_continue(:start_initial_token, state) do
    start_node = if state.start_node_id do
      Definition.get_node(state.definition, state.start_node_id)
    else
      Definition.get_blank_start_event(state.definition)
    end

    case start_node do
      nil ->
        Logger.error("Instance #{state.id}: No start event found")
        {:stop, :no_start_event, state}

      node ->
        {token, state} = TokenState.create_token(state, 0, node.id, state.start_parameters || %{})
        state = %{state | active_tokens: MapSet.put(state.active_tokens, token.id)}
        {:noreply, state, {:continue, :process_tokens}}
    end
  end

  def handle_continue({:restore, events}, state) do
    case EventReplayer.restore_from_events(events, state) do
      {:ok, state} ->
        Phoenix.PubSub.broadcast(Chronicle.PubSub, "engine:events",
          {:process_instance_resumed, state.id})

        cond do
          MapSet.size(state.active_tokens) > 0 ->
            {:noreply, state, {:continue, :process_tokens}}

          MapSet.size(state.waiting_tokens) > 0 ->
            {:noreply, state, :hibernate}

          true ->
            {:noreply, state}
        end

      {:error, reason} ->
        Logger.error("Instance #{state.id}: Restoration failed: #{inspect(reason)}")
        {:stop, {:restoration_failed, reason}, state}
    end
  end

  def handle_continue(:process_tokens, state) do
    state = Chronicle.Engine.TokenProcessor.process_active_tokens(state)

    case sync_persist(state) do
      {:ok, state} ->
        cond do
          MapSet.size(state.active_tokens) > 0 ->
            {:noreply, state, {:continue, :process_tokens}}

          MapSet.size(state.waiting_tokens) == 0 and MapSet.size(state.active_tokens) == 0 ->
            case complete_instance(state) do
              {:ok, state} ->
                {:noreply, state}

              {:error, reason, state} ->
                # Completion persistence failed — stop so the supervisor can
                # restart and replay from the durable log. Hibernating would
                # strand the instance with no active/waiting tokens and no
                # retry path.
                {:stop, {:persist_failed, reason}, state}
            end

          true ->
            state = %{state | instance_state: :waiting, pin_state: :not_pinned, pin_reason: :none}
            {:noreply, state, :hibernate}
        end

      {:error, _reason, state} ->
        # In-cycle persistence failed. Do not continue token processing and
        # do not publish any downstream event. Hibernate so the next inbound
        # message (or a supervisor-driven restart) retries.
        {:noreply, state, :hibernate}
    end
  end

  # --- Message/Signal Delivery ---

  @impl true
  def handle_cast({:message, message_name, payload}, state) do
    case WaitRegistry.handle_message(state, message_name, payload) do
      {:ignored, state} -> {:noreply, state}
      {:boundary, state} -> {:noreply, state, {:continue, :process_tokens}}
      {:resumed, state} -> {:noreply, state, {:continue, :process_tokens}}
    end
  end

  def handle_cast({:signal, signal_name}, state) do
    state = WaitRegistry.handle_signal(state, signal_name)

    if MapSet.size(state.active_tokens) > 0 do
      {:noreply, state, {:continue, :process_tokens}}
    else
      {:noreply, state}
    end
  end

  def handle_cast({:external_task_complete, task_id, payload, result}, state) do
    case WaitRegistry.complete_external_task(state, task_id, payload, result) do
      {:error, :not_found} ->
        Logger.warning("Instance #{state.id}: Unknown external task #{task_id}")
        {:noreply, state}

      {:ok, state, token_id} ->
        # Persist completion event
        token = Map.get(state.tokens, token_id)
        event = %PersistentData.ExternalTaskCompletion{
          token: token_id,
          family: token && token.family,
          current_node: token && token.current_node,
          external_task: task_id,
          successful: true,
          payload: payload,
          result: result
        }
        state = append_event(state, event)

        case sync_persist(state) do
          {:ok, state} ->
            Phoenix.PubSub.broadcast(Chronicle.PubSub, "engine:events",
              {:external_task_completed, state.id, task_id, true})

            {:noreply, state, {:continue, :process_tokens}}

          {:error, _reason, state} ->
            # Do not publish completion or continue token processing. The
            # next redelivery / external retry will re-invoke this handler.
            {:noreply, state}
        end
    end
  end

  def handle_cast({:external_task_error, task_id, error, retry?, backoff_ms}, state) do
    case WaitRegistry.error_external_task(state, task_id, error, retry?, backoff_ms) do
      {:error, :not_found} -> {:noreply, state}
      {:ok, state} -> {:noreply, state, {:continue, :process_tokens}}
    end
  end

  def handle_cast({:terminate, reason}, state) do
    candidate = TokenState.terminate_all_tokens(state, reason)

    case persist_termination(candidate, reason) do
      :ok ->
        candidate = %{candidate | last_persisted_index: length(candidate.persistent_events)}

        Phoenix.PubSub.broadcast(Chronicle.PubSub, "engine:events",
          {:process_instance_terminated, candidate.id, candidate.business_key, candidate.tenant_id, reason})

        {:noreply, candidate}

      {:error, err} ->
        Logger.error("Instance #{state.id}: Termination persistence failed: #{inspect(err)}")
        # Do not publish termination or accept terminated state. Keep the
        # instance in its prior state so a retry/replay can resolve it.
        {:noreply, state}
    end
  end

  def handle_cast(:force_pin, state) do
    {:noreply, %{state | pin_state: :force_pinned, pin_reason: :api}}
  end

  def handle_cast(:remove_force_pin, state) do
    {:noreply, %{state | pin_state: :not_pinned, pin_reason: :none}}
  end

  # Script result from pool worker
  def handle_cast({:script_result, ref, result}, state) do
    case WaitRegistry.handle_script_result(state, ref, result) do
      {:error, :not_found} -> {:noreply, state}
      {:ok, state} -> {:noreply, state, {:continue, :process_tokens}}
    end
  end

  # Expression results from pool worker
  def handle_cast({:expressions_result, ref, result}, state) do
    case WaitRegistry.handle_script_result(state, ref, result) do
      {:error, :not_found} -> {:noreply, state}
      {:ok, state} -> {:noreply, state, {:continue, :process_tokens}}
    end
  end

  # Rules result
  def handle_cast({:rules_result, ref, result}, state) do
    case WaitRegistry.handle_script_result(state, ref, result) do
      {:error, :not_found} -> {:noreply, state}
      {:ok, state} -> {:noreply, state, {:continue, :process_tokens}}
    end
  end

  # Child process completed (CallActivity)
  def handle_cast({:child_completed, child_id, completion_context, successful}, state) do
    case WaitRegistry.handle_child_completed(state, child_id, completion_context, successful) do
      {:error, :not_found} -> {:noreply, state}
      {:ok, state} -> {:noreply, state, {:continue, :process_tokens}}
    end
  end

  # --- Timer handling ---

  @impl true
  def handle_info({:timer_elapsed, token_id, timer_ref}, state) do
    case WaitRegistry.handle_timer_elapsed(state, token_id, timer_ref) do
      {:resumed, state} ->
        state = append_timer_elapsed_event(state, token_id)

        case sync_persist(state) do
          {:ok, state} ->
            {:noreply, state, {:continue, :process_tokens}}

          {:error, _reason, state} ->
            # Hibernate without publishing; timer will re-fire or instance
            # will be restored from the event log after a crash.
            {:noreply, state, :hibernate}
        end

      {:ignored, state} ->
        {:noreply, state}
    end
  end

  def handle_info({:boundary_timer_elapsed, token_id, boundary_node_id, timer_ref}, state) do
    case WaitRegistry.handle_boundary_timer_elapsed(state, token_id, boundary_node_id, timer_ref) do
      {:resumed, state} ->
        state = append_timer_elapsed_event(state, token_id)

        case sync_persist(state) do
          {:ok, state} ->
            {:noreply, state, {:continue, :process_tokens}}

          {:error, _reason, state} ->
            {:noreply, state, :hibernate}
        end

      {:ignored, state} ->
        {:noreply, state}
    end
  end

  defp append_timer_elapsed_event(state, token_id) do
    token = Map.get(state.tokens, token_id)
    timer_id = token && (token.context[:intermediate_timer_id] || token.context[:timer_id])

    event = %PersistentData.TimerElapsed{
      token: token_id,
      family: token && token.family,
      current_node: token && token.current_node,
      target_node: token && token.current_node,
      timer_id: timer_id,
      retry_counter: token && token.context[:retries],
      triggered_at: System.system_time(:millisecond)
    }

    append_event(state, event)
  end

  @impl true
  def handle_call(:inspect, _from, state) do
    info = %{
      id: state.id,
      business_key: state.business_key,
      tenant_id: state.tenant_id,
      state: state.instance_state,
      active_tokens: MapSet.to_list(state.active_tokens),
      waiting_tokens: MapSet.to_list(state.waiting_tokens),
      completed_tokens: MapSet.to_list(state.completed_tokens),
      token_count: map_size(state.tokens),
      external_tasks: Map.keys(state.external_tasks),
      message_waits: Map.keys(state.message_waits),
      signal_waits: Map.keys(state.signal_waits),
      pin_state: state.pin_state,
      tokens: Enum.map(state.tokens, fn {id, t} ->
        %{id: id, state: t.state, current_node: t.current_node, family: t.family}
      end)
    }
    {:reply, info, state}
  end

  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  def handle_call({:migrate, new_definition, node_mappings}, _from, state) do
    state = Migration.migrate(state, new_definition, node_mappings)

    case sync_persist(state) do
      {:ok, state} ->
        {:reply, :ok, state}

      {:error, reason, state} ->
        {:reply, {:error, {:persist_failed, reason}}, state}
    end
  end

  # --- Internal Helpers ---

  defp complete_instance(state) do
    completion_data = state.completed_tokens
      |> MapSet.to_list()
      |> Enum.map(&Map.get(state.tokens, &1))
      |> Enum.filter(&(&1 != nil))
      |> Enum.map(& &1.context[:completion_data])
      |> Enum.reject(&is_nil/1)

    candidate = %{state | instance_state: :completed, pin_state: :not_pinned, pin_reason: :none}

    case persist_completion(candidate) do
      :ok ->
        # After a successful complete/3 the active row is deleted and the
        # completed row carries the full event list; treat as fully persisted.
        candidate = %{candidate | last_persisted_index: length(candidate.persistent_events)}

        Phoenix.PubSub.broadcast(Chronicle.PubSub, "engine:events",
          {:process_instance_completed, candidate.id, candidate.business_key, candidate.tenant_id, completion_data})

        if candidate.parent_id do
          case lookup(candidate.tenant_id, candidate.parent_id) do
            {:ok, parent_pid} ->
              GenServer.cast(parent_pid, {:child_completed, candidate.id, completion_data, true})
            _ -> :ok
          end
        end

        if Chronicle.Engine.LargeVariablesCleaner.enabled?() do
          cleanup_state = candidate
          Task.start(fn ->
            all_params = cleanup_state.tokens |> Map.values() |> Enum.map(& &1.parameters)
            Enum.each(all_params, &Chronicle.Engine.LargeVariablesCleaner.cleanup(&1, cleanup_state.tenant_id))
          end)
        end

        {:ok, candidate}

      {:error, reason} ->
        Logger.error("Instance #{state.id}: Completion persistence failed, leaving instance active: #{inspect(reason)}")
        # Do NOT publish the completion event nor notify the parent.
        # Keep the instance in its pre-completion state so a supervisor
        # restart (or retry) can replay from the durable log.
        {:error, reason, state}
    end
  end

  defp append_event(state, event) do
    %{state | persistent_events: state.persistent_events ++ [event]}
  end

  # --- Persistence helpers ---

  @doc false
  # Synchronously flushes any events appended to `state.persistent_events`
  # since the last persist. On success returns `{:ok, state}` with
  # `last_persisted_index` bumped to the current length. On failure returns
  # `{:error, reason, state}` so callers can abort downstream publishing.
  #
  # Callers MUST NOT publish downstream events (PubSub broadcasts, parent
  # notifications, AMQP acks etc.) when this returns `:error` — the durable
  # transition has not been written.
  defp sync_persist(%{instance_state: :simulating} = state), do: {:ok, state}
  defp sync_persist(state) do
    total = length(state.persistent_events)
    delta = total - state.last_persisted_index

    cond do
      delta <= 0 ->
        {:ok, state}

      true ->
        pending = Enum.drop(state.persistent_events, state.last_persisted_index)

        case safe_append_batch(state.id, pending) do
          :ok ->
            {:ok, %{state | last_persisted_index: total}}

          {:error, reason} ->
            Logger.error("Instance #{state.id}: Failed to persist #{delta} events: #{inspect(reason)}")
            {:error, reason, state}
        end
    end
  end

  defp safe_append_batch(instance_id, events) do
    try do
      case Chronicle.Persistence.EventStore.append_batch(instance_id, events) do
        {:ok, _} -> :ok
        :ok -> :ok
        other -> {:error, other}
      end
    rescue
      e -> {:error, e}
    catch
      :exit, reason -> {:error, {:exit, reason}}
    end
  end

  # Synchronous completion persistence. Called inline — Ecto calls are already
  # synchronous, and wrapping in Task.async + Task.await only adds linked-task
  # failure semantics without changing timeout behaviour (Ecto's own pool
  # timeout raises on DB stalls just the same).
  # Returns :ok on success, {:error, reason} on failure.
  defp persist_completion(state) do
    case Chronicle.Persistence.EventStore.complete(state.id, state.persistent_events) do
      {:ok, _} -> :ok
      other -> {:error, other}
    end
  rescue
    e -> {:error, e}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp persist_termination(state, reason) do
    case Chronicle.Persistence.EventStore.terminate(state.id, state.persistent_events, reason) do
      {:ok, _} -> :ok
      other -> {:error, other}
    end
  rescue
    e -> {:error, e}
  catch
    :exit, exit_reason -> {:error, {:exit, exit_reason}}
  end
end
