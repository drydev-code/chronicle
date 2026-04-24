defmodule Chronicle.Engine.Instance do
  @moduledoc """
  GenServer per workflow instance (ProcessInstanceV2 equivalent).
  Each running BPMN process instance is a separate GenServer.
  """
  use GenServer, restart: :temporary

  require Logger

  alias Chronicle.Engine.{Token, PersistentData}
  alias Chronicle.Engine.Diagrams.Definition
  alias Chronicle.Engine.Instance.{TokenState, EventReplayer, WaitRegistry, Migration, BoundaryLifecycle}

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

  def send_message_sync(pid, message_name, payload \\ %{}, timeout \\ 30_000) do
    GenServer.call(pid, {:message, message_name, payload}, timeout)
  end

  def send_signal(pid, signal_name) do
    GenServer.cast(pid, {:signal, signal_name})
  end

  def send_signal_sync(pid, signal_name, timeout \\ 30_000) do
    GenServer.call(pid, {:signal, signal_name}, timeout)
  end

  def complete_external_task(pid, task_id, payload, result) do
    GenServer.cast(pid, {:external_task_complete, task_id, payload, result})
  end

  def complete_external_task_sync(pid, task_id, payload, result, timeout \\ 30_000) do
    GenServer.call(pid, {:external_task_complete, task_id, payload, result}, timeout)
  end

  def error_external_task(pid, task_id, error, retry?, backoff_ms) do
    GenServer.cast(pid, {:external_task_error, task_id, error, retry?, backoff_ms})
  end

  def error_external_task_sync(pid, task_id, error, retry?, backoff_ms, timeout \\ 30_000) do
    GenServer.call(pid, {:external_task_error, task_id, error, retry?, backoff_ms}, timeout)
  end

  def cancel_external_task(pid, task_id, reason, continuation_node_id \\ nil) do
    GenServer.cast(pid, {:external_task_cancel, task_id, reason, continuation_node_id})
  end

  def cancel_external_task_sync(pid, task_id, reason, continuation_node_id \\ nil, timeout \\ 30_000) do
    GenServer.call(pid, {:external_task_cancel, task_id, reason, continuation_node_id}, timeout)
  end

  def cancel_call(pid, child_id, next_node \\ nil) do
    GenServer.cast(pid, {:call_cancel, child_id, next_node})
  end

  def cancel_call_sync(pid, child_id, next_node \\ nil, timeout \\ 30_000) do
    GenServer.call(pid, {:call_cancel, child_id, next_node}, timeout)
  end

  def retrigger_conditionals(pid, variables \\ %{}) do
    GenServer.cast(pid, {:retrigger_conditionals, variables})
  end

  def update_variables(pid, variables) when is_map(variables) do
    GenServer.cast(pid, {:update_variables, variables})
  end

  def update_variables_sync(pid, variables, timeout \\ 30_000) when is_map(variables) do
    GenServer.call(pid, {:update_variables, variables}, timeout)
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
        state = append_event(state, %PersistentData.TokenFamilyCreated{
          token: token.id,
          family: token.family,
          current_node: token.current_node,
          start_params: token.parameters
        })
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
        state = publish_pending_effects(state)

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
    command_reply(do_message_command(state, message_name, payload))
  end

  def handle_cast({:signal, signal_name}, state) do
    command_reply(do_signal_command(state, signal_name))
  end

  def handle_cast({:external_task_complete, task_id, payload, result}, state) do
    command_reply(do_external_task_complete(state, task_id, payload, result))
  end

  def handle_cast({:external_task_error, task_id, error, retry?, backoff_ms}, state) do
    command_reply(do_external_task_error(state, task_id, error, retry?, backoff_ms))
  end

  def handle_cast({:external_task_cancel, task_id, reason, continuation_node_id}, state) do
    command_reply(do_external_task_cancel(state, task_id, reason, continuation_node_id))
  end

  def handle_cast({:terminate, reason}, state) do
    boundary_events = all_boundary_cancellation_events(state)
    candidate =
      state
      |> append_events(boundary_events)
      |> TokenState.terminate_all_tokens(reason)

    case persist_termination(candidate, reason) do
      :ok ->
        candidate = %{candidate | last_persisted_index: length(candidate.persistent_events)}
        candidate = cancel_all_boundary_registrations(candidate)

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
    handle_script_like_result(state, ref, result)
  end

  # Expression results from pool worker
  def handle_cast({:expressions_result, ref, result}, state) do
    handle_script_like_result(state, ref, result)
  end

  # Rules result
  def handle_cast({:rules_result, ref, result}, state) do
    handle_script_like_result(state, ref, result)
  end

  # Child process completed (CallActivity)
  def handle_cast({:child_completed, child_id, completion_context, successful}, state) do
    case Map.get(state.call_wait_list, child_id) do
      nil ->
        {:noreply, state}

      token_id ->
        token = Map.get(state.tokens, token_id)
        event = %PersistentData.CallCompleted{
          token: token_id,
          family: token && token.family,
          current_node: token && token.current_node,
          completion_context: completion_context,
          successful: successful,
          loop_index: token && token.context[:step]
        }

        events = BoundaryLifecycle.cancellation_events(state, token_id) ++ [event]

        case persist_command_events(state, events) do
          {:ok, state} ->
            state = WaitRegistry.cancel_boundary_registrations(state, token_id)

            case WaitRegistry.handle_child_completed(state, child_id, completion_context, successful) do
              {:error, :not_found} -> {:noreply, state}
              {:ok, state} -> {:noreply, state, {:continue, :process_tokens}}
            end

          {:error, _reason, state} ->
            {:noreply, state}
        end
    end
  end

  def handle_cast({:call_cancel, child_id, next_node}, state) do
    command_reply(do_call_cancel(state, child_id, next_node))
  end

  def handle_cast({:retrigger_conditionals, variables}, state) do
    {:noreply, retrigger_conditional_tokens(state, variables)}
  end

  def handle_cast({:update_variables, variables}, state) do
    command_reply(do_update_variables(state, variables))
  end

  defp handle_script_like_result(state, ref, result) do
    case Map.get(state.script_waits, ref) do
      nil ->
        {:noreply, state}

      token_id ->
        events = BoundaryLifecycle.cancellation_events(state, token_id)

        case persist_command_events(state, events) do
          {:ok, state} ->
            state = WaitRegistry.cancel_boundary_registrations(state, token_id)

            case WaitRegistry.handle_script_result(state, ref, result) do
              {:error, :not_found} -> {:noreply, state}
              {:ok, state} -> {:noreply, state, {:continue, :process_tokens}}
            end

          {:error, _reason, state} ->
            {:noreply, state}
        end
    end
  end

  # --- Timer handling ---

  @impl true
  def handle_info({:timer_elapsed, token_id, timer_marker}, state) do
    {timer_ref, timer_id} = resolve_timer_ref(state, token_id, timer_marker)

    case WaitRegistry.handle_timer_elapsed(state, token_id, timer_ref) do
      {:resumed, state} ->
        state = append_timer_elapsed_event(state, token_id, timer_id)
        state = %{state | timer_ref_ids: Map.delete(state.timer_ref_ids || %{}, timer_ref)}

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

  def handle_info({:boundary_timer_elapsed, token_id, boundary_node_id, timer_marker}, state) do
    {timer_ref, timer_id} = resolve_timer_ref(state, token_id, timer_marker)

    trigger_event = BoundaryLifecycle.trigger_event(state, token_id, boundary_node_id)

    cancel_events =
      if BoundaryLifecycle.interrupting?(state, token_id, boundary_node_id) do
        BoundaryLifecycle.activity_timer_cancellation_events(state, token_id) ++
          BoundaryLifecycle.cancellation_events(state, token_id, boundary_node_id)
      else
        []
      end

    timer_event = timer_elapsed_event(state, token_id, timer_id)

    case persist_command_events(state, [timer_event, trigger_event | cancel_events]) do
      {:ok, state} ->
        handle_persisted_boundary_timer_elapsed(state, token_id, boundary_node_id, timer_ref)

      {:error, _reason, state} ->
        {:noreply, state, :hibernate}
    end
  end

  defp handle_persisted_boundary_timer_elapsed(state, token_id, boundary_node_id, timer_ref) do
    case WaitRegistry.handle_boundary_timer_elapsed(state, token_id, boundary_node_id, timer_ref) do
      {:resumed, state} ->
        state = %{state | timer_ref_ids: Map.delete(state.timer_ref_ids || %{}, timer_ref)}

        if BoundaryLifecycle.interrupting?(state, token_id, boundary_node_id) do
          state =
            state
            |> WaitRegistry.cancel_activity_timer_registrations(token_id)
            |> WaitRegistry.cancel_boundary_registrations(token_id)

          {:noreply, state, {:continue, :process_tokens}}
        else
          state = WaitRegistry.close_triggered_boundary_registration(state, token_id, boundary_node_id)
          {:noreply, state, {:continue, :process_tokens}}
        end

      {:ignored, state} ->
        {:noreply, state}
    end
  end

  defp append_timer_elapsed_event(state, token_id, timer_id) do
    append_event(state, timer_elapsed_event(state, token_id, timer_id))
  end

  defp timer_elapsed_event(state, token_id, timer_id) do
    token = Map.get(state.tokens, token_id)
    timer_id = timer_id || (token && (token.context[:intermediate_timer_id] || token.context[:timer_id]))

    %PersistentData.TimerElapsed{
      token: token_id,
      family: token && token.family,
      current_node: token && token.current_node,
      target_node: token && token.current_node,
      timer_id: timer_id,
      retry_counter: token && token.context[:retries],
      triggered_at: System.system_time(:millisecond)
    }
  end

  defp resolve_timer_ref(state, token_id, marker) do
    cond do
      Map.has_key?(state.timer_refs || %{}, marker) ->
        {marker, Map.get(state.timer_ref_ids || %{}, marker)}

      true ->
        found =
          Enum.find(state.timer_refs || %{}, fn {ref, owner_token_id} ->
            owner_token_id == token_id and Map.get(state.timer_ref_ids || %{}, ref) == marker
          end)

        case found do
          {ref, _token_id} -> {ref, marker}
          nil -> {marker, marker}
        end
    end
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

  def handle_call({:message, message_name, payload}, _from, state) do
    command_call_reply(do_message_command(state, message_name, payload))
  end

  def handle_call({:signal, signal_name}, _from, state) do
    command_call_reply(do_signal_command(state, signal_name))
  end

  def handle_call({:external_task_complete, task_id, payload, result}, _from, state) do
    command_call_reply(do_external_task_complete(state, task_id, payload, result))
  end

  def handle_call({:external_task_error, task_id, error, retry?, backoff_ms}, _from, state) do
    command_call_reply(do_external_task_error(state, task_id, error, retry?, backoff_ms))
  end

  def handle_call({:external_task_cancel, task_id, reason, continuation_node_id}, _from, state) do
    command_call_reply(do_external_task_cancel(state, task_id, reason, continuation_node_id))
  end

  def handle_call({:call_cancel, child_id, next_node}, _from, state) do
    command_call_reply(do_call_cancel(state, child_id, next_node))
  end

  def handle_call({:update_variables, variables}, _from, state) do
    command_call_reply(do_update_variables(state, variables))
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

  defp append_events(state, events) do
    %{state | persistent_events: state.persistent_events ++ events}
  end

  defp command_reply({:ok, state, true}), do: {:noreply, state, {:continue, :process_tokens}}
  defp command_reply({:ok, state, false}), do: {:noreply, state}
  defp command_reply({:error, _reason, state}), do: {:noreply, state}

  defp command_call_reply({:ok, state, true}), do: {:reply, :ok, state, {:continue, :process_tokens}}
  defp command_call_reply({:ok, state, false}), do: {:reply, :ok, state}
  defp command_call_reply({:error, reason, state}), do: {:reply, {:error, reason}, state}

  defp do_message_command(state, message_name, payload) do
    events = message_command_events(state, message_name, payload)

    case persist_command_events(state, events) do
      {:ok, state} ->
        state = apply_activity_timer_cancellations(state, events)

        case WaitRegistry.handle_message(state, message_name, payload) do
          {:ignored, state} ->
            {:ok, state, false}

          {:boundary, state} ->
            state = cleanup_interrupted_activity_timers(state)
            {:ok, state, true}

          {:resumed, state} ->
            {:ok, state, true}
        end

      {:error, reason, state} ->
        {:error, reason, state}
    end
  end

  defp do_signal_command(state, signal_name) do
    events = signal_command_events(state, signal_name)

    case persist_command_events(state, events) do
      {:ok, state} ->
        state =
          state
          |> apply_activity_timer_cancellations(events)
          |> WaitRegistry.handle_signal(signal_name)
          |> cleanup_interrupted_activity_timers()

        {:ok, state, MapSet.size(state.active_tokens) > 0}

      {:error, reason, state} ->
        {:error, reason, state}
    end
  end

  defp do_external_task_complete(state, task_id, payload, result) do
    case Map.get(state.external_tasks, task_id) do
      nil ->
        Logger.warning("Instance #{state.id}: Unknown external task #{task_id}")
        {:error, :not_found, state}

      token_id ->
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

        events = BoundaryLifecycle.cancellation_events(state, token_id) ++ [event]

        case persist_command_events(state, events) do
          {:ok, state} ->
            state = WaitRegistry.cancel_boundary_registrations(state, token_id)

            case WaitRegistry.complete_external_task(state, task_id, payload, result) do
              {:ok, state, _token_id} ->
                Phoenix.PubSub.broadcast(Chronicle.PubSub, "engine:events",
                  {:external_task_completed, state.id, task_id, true})

                {:ok, state, true}

              {:error, :not_found} ->
                {:error, :not_found, state}
            end

          {:error, reason, state} ->
            {:error, reason, state}
        end
    end
  end

  defp do_external_task_error(state, task_id, error, retry?, backoff_ms) do
    case Map.get(state.external_tasks, task_id) do
      nil ->
        {:error, :not_found, state}

      token_id ->
        token = Map.get(state.tokens, token_id)

        event = %PersistentData.ExternalTaskCompletion{
          token: token_id,
          family: token && token.family,
          current_node: token && token.current_node,
          external_task: task_id,
          successful: false,
          error: error,
          retry_counter: token && token.context[:retries]
        }

        {events, boundary_cleanup?} =
          external_task_error_events(state, token, retry?, error, event)

        case persist_command_events(state, events) do
          {:ok, state} ->
            state =
              if boundary_cleanup? do
                WaitRegistry.cancel_boundary_registrations(state, token_id)
              else
                state
              end

            case WaitRegistry.error_external_task(state, task_id, error, retry?, backoff_ms) do
              {:error, :not_found} -> {:error, :not_found, state}
              {:ok, state} -> {:ok, state, true}
            end

          {:error, reason, state} ->
            {:error, reason, state}
        end
    end
  end

  defp do_external_task_cancel(state, task_id, reason, continuation_node_id) do
    case Map.get(state.external_tasks, task_id) do
      nil ->
        {:error, :not_found, state}

      token_id ->
        token = Map.get(state.tokens, token_id)
        continuation_node_id = continuation_node_id || first_output_for_token(state, token)

        event = %PersistentData.ExternalTaskCancellation{
          token: token_id,
          family: token && token.family,
          current_node: token && token.current_node,
          external_task: task_id,
          cancellation_reason: reason,
          continuation_node_id: continuation_node_id,
          retry_counter: token && token.context[:retries]
        }

        events = BoundaryLifecycle.cancellation_events(state, token_id) ++ [event]

        case persist_command_events(state, events) do
          {:ok, state} ->
            state =
              state
              |> WaitRegistry.cancel_boundary_registrations(token_id)
              |> WaitRegistry.cancel_external_task(task_id, reason, continuation_node_id)

            {:ok, state, true}

          {:error, reason, state} ->
            {:error, reason, state}
        end
    end
  end

  defp do_call_cancel(state, child_id, next_node) do
    case Map.get(state.call_wait_list, child_id) do
      nil ->
        {:error, :not_found, state}

      token_id ->
        token = Map.get(state.tokens, token_id)
        next_node = next_node || first_output_for_token(state, token)

        event = %PersistentData.CallCanceled{
          token: token_id,
          family: token && token.family,
          current_node: token && token.current_node,
          next_node: next_node
        }

        events = BoundaryLifecycle.cancellation_events(state, token_id) ++ [event]

        case persist_command_events(state, events) do
          {:ok, state} ->
            state =
              state
              |> WaitRegistry.cancel_boundary_registrations(token_id)
              |> WaitRegistry.cancel_call(child_id, next_node)

            {:ok, state, true}

          {:error, reason, state} ->
            {:error, reason, state}
        end
    end
  end

  defp do_update_variables(state, variables) do
    events =
      state.tokens
      |> Enum.filter(fn {_id, token} ->
        token.state in [
          :execute_current_node,
          :move_to_next_node,
          :continue,
          :waiting_for_timer,
          :waiting_for_message,
          :waiting_for_signal,
          :waiting_for_event_gateway,
          :waiting_for_script,
          :waiting_for_call,
          :waiting_for_external_task,
          :waiting_for_conditional_event
        ]
      end)
      |> Enum.map(fn {_id, token} ->
        %PersistentData.VariablesUpdated{
          token: token.id,
          family: token.family,
          current_node: token.current_node,
          variables: variables,
          updated_at: System.system_time(:millisecond)
        }
      end)

    case persist_command_events(state, events) do
      {:ok, state} ->
        state =
          events
          |> Enum.reduce(state, fn event, acc ->
            token = Map.get(acc.tokens, event.token)
            token = %{token | parameters: Map.merge(token.parameters || %{}, variables)}
            %{acc | tokens: Map.put(acc.tokens, token.id, token)}
          end)
          |> retrigger_conditional_tokens(%{})

        {:ok, state, false}

      {:error, reason, state} ->
        {:error, reason, state}
    end
  end

  defp retrigger_conditional_tokens(state, variables) do
    conditional_tokens =
      state.waiting_tokens
      |> Enum.map(&Map.get(state.tokens, &1))
      |> Enum.reject(&is_nil/1)
      |> Enum.filter(&(&1.state == :waiting_for_conditional_event))

    Enum.reduce(conditional_tokens, state, fn token, acc ->
      node = Definition.get_node(acc.definition, token.current_node)
      params = Map.merge(token.parameters || %{}, variables || %{})
      token = %{token | parameters: params}
      ref = make_ref()

      Chronicle.Engine.Scripting.ScriptPool.execute_expressions(
        ref,
        [{node.id, node.condition}],
        params,
        self()
      )

      %{acc |
        tokens: Map.put(acc.tokens, token.id, token),
        script_waits: Map.put(acc.script_waits, ref, token.id)
      }
    end)
  end

  defp persist_command_events(state, []), do: {:ok, state}
  defp persist_command_events(state, events) do
    state
    |> append_events(events)
    |> sync_persist()
  end

  defp publish_pending_effects(state) do
    Enum.each(state.pending_effects || [], fn
      {:pubsub, topic, message} ->
        Phoenix.PubSub.broadcast(Chronicle.PubSub, topic, message)
    end)

    %{state | pending_effects: []}
  end

  defp message_command_events(state, message_name, payload) do
    wait_events =
      case Map.get(state.message_waits, message_name, []) do
        [token_id | _] ->
          token = Map.get(state.tokens, token_id)
          [%PersistentData.MessageHandled{
            token: token_id,
            family: token && token.family,
            current_node: token && token.current_node,
            name: message_name,
            target_node: token && token.current_node,
            retry_counter: token && token.context[:retries],
            payload: payload
          }]

        [] ->
          []
      end

    boundary_trigger_events(state, :message, message_name)
    |> Kernel.++(wait_events)
  end

  defp signal_command_events(state, signal_name) do
    wait_events =
      Enum.map(Map.get(state.signal_waits, signal_name, []), fn token_id ->
        token = Map.get(state.tokens, token_id)
        %PersistentData.SignalHandled{
          token: token_id,
          family: token && token.family,
          current_node: token && token.current_node,
          signal_name: signal_name,
          target_node: token && token.current_node,
          retry_counter: token && token.context[:retries]
        }
      end)

    boundary_trigger_events(state, :signal, signal_name) ++ wait_events
  end

  defp boundary_trigger_events(state, type, name) do
    {interrupting, non_interrupting} =
      case type do
        :message -> {state.message_boundaries, state.ni_message_boundaries}
        :signal -> {state.signal_boundaries, state.ni_signal_boundaries}
      end

    Enum.flat_map([{interrupting, true}, {non_interrupting, false}], fn {map, interrupting?} ->
      map
      |> Map.get(name, [])
      |> Enum.flat_map(fn {token_id, boundary_node} ->
        trigger_event = BoundaryLifecycle.trigger_event(state, token_id, boundary_node.id)

        if interrupting? do
          [trigger_event] ++
            BoundaryLifecycle.activity_timer_cancellation_events(state, token_id) ++
            BoundaryLifecycle.cancellation_events(state, token_id, boundary_node.id)
        else
          [trigger_event]
        end
      end)
    end)
  end

  defp cleanup_interrupted_activity_timers(state) do
    active_tokens =
      state.active_tokens
      |> MapSet.to_list()
      |> Enum.map(&Map.get(state.tokens, &1))
      |> Enum.reject(&is_nil/1)
      |> Enum.filter(&Map.has_key?(state.boundary_index || %{}, &1.id))
      |> Enum.filter(&(&1.state == :execute_current_node))

    Enum.reduce(active_tokens, state, fn token, acc ->
      WaitRegistry.cancel_activity_timer_registrations(acc, token.id)
    end)
  end

  defp apply_activity_timer_cancellations(state, events) do
    events
    |> Enum.filter(&match?(%PersistentData.TimerCanceled{}, &1))
    |> Enum.map(& &1.token)
    |> Enum.uniq()
    |> Enum.reduce(state, fn token_id, acc ->
      WaitRegistry.cancel_activity_timer_registrations(acc, token_id)
    end)
  end

  defp all_boundary_cancellation_events(state) do
    state.boundary_index
    |> Map.keys()
    |> Enum.flat_map(&BoundaryLifecycle.cancellation_events(state, &1))
  end

  defp cancel_all_boundary_registrations(state) do
    state.boundary_index
    |> Map.keys()
    |> Enum.reduce(state, &WaitRegistry.cancel_boundary_registrations(&2, &1))
  end

  defp first_output_for_token(_state, nil), do: nil

  defp first_output_for_token(state, token) do
    state.definition
    |> Definition.get_node(token.current_node)
    |> case do
      nil -> nil
      node -> List.first(Map.get(node, :outputs, []) || [])
    end
  end

  defp external_task_error_events(_state, nil, _retry?, _error, event), do: {[event], false}

  defp external_task_error_events(_state, _token, true, _error, event) do
    # A retry keeps the activity alive, so its boundary registrations remain
    # open and can still interrupt the retry wait.
    {[event], false}
  end

  defp external_task_error_events(state, token, false, error, event) do
    node = Definition.get_node(state.definition, token.current_node)
    boundary = Chronicle.Engine.Nodes.Activity.get_boundary_event_to_error(node || %{}, error)

    if boundary do
      trigger = BoundaryLifecycle.trigger_event(state, token.id, boundary.id)
      cancellations = BoundaryLifecycle.cancellation_events(state, token.id, boundary.id)
      {[event, trigger | cancellations], true}
    else
      {BoundaryLifecycle.cancellation_events(state, token.id) ++ [event], true}
    end
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
