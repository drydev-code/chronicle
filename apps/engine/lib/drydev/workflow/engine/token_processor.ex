defmodule DryDev.Workflow.Engine.TokenProcessor do
  @moduledoc """
  Token update loop - pure functions called inside Instance GenServer.
  Processes active tokens and handles NodeResult outcomes.
  """

  alias DryDev.Workflow.Engine.{Token, ExecutionContext, PersistentData}
  alias DryDev.Workflow.Engine.Diagrams.Definition
  alias DryDev.Workflow.Engine.Nodes

  require Logger

  def process_active_tokens(state) do
    active_list = MapSet.to_list(state.active_tokens)
    Enum.reduce(active_list, state, &update_token/2)
  end

  defp update_token(token_id, state) do
    token = Map.get(state.tokens, token_id)
    if token == nil, do: state, else: do_update_token(token, state)
  end

  defp do_update_token(%{state: :execute_current_node} = token, state) do
    node = Definition.get_node(state.definition, token.current_node)
    if node == nil do
      Logger.error("Instance #{state.id}: Node #{token.current_node} not found")
      crash_token(state, token)
    else
      context = build_context(state, token, node)
      try do
        result = dispatch_process(node, context)
        handle_node_result(state, token, result)
      rescue
        e ->
          Logger.error("Instance #{state.id}: Node #{token.current_node} raised: #{inspect(e)}")
          handle_error_in_activity(state, token, node, e)
      end
    end
  end

  defp do_update_token(%{state: :move_to_next_node} = token, state) do
    token = Token.advance(token)
    %{state | tokens: Map.put(state.tokens, token.id, token)}
  end

  defp do_update_token(%{state: :continue} = token, state) do
    node = Definition.get_node(state.definition, token.current_node)
    if node == nil do
      crash_token(state, token)
    else
      context = build_context(state, token, node)
      try do
        result = dispatch_continue(node, context)
        handle_node_result(state, token, result)
      rescue
        e ->
          handle_error_in_activity(state, token, node, e)
      end
    end
  end

  defp do_update_token(_token, state), do: state

  # --- Dispatch to node modules ---

  defp dispatch_process(node, context) do
    module = node_module(node)
    if module, do: module.process(context), else: {:next, List.first(Map.get(node, :outputs, []))}
  end

  defp dispatch_continue(node, context) do
    module = node_module(node)
    if module, do: module.continue_after_wait(context), else: {:next, List.first(Map.get(node, :outputs, []))}
  end

  defp node_module(%Nodes.ScriptTask{}), do: Nodes.ScriptTask
  defp node_module(%Nodes.ExternalTask{}), do: Nodes.ExternalTask
  defp node_module(%Nodes.CallActivity{}), do: Nodes.CallActivity
  defp node_module(%Nodes.RulesTask{}), do: Nodes.RulesTask
  defp node_module(%Nodes.Gateway{}), do: Nodes.Gateway
  defp node_module(%Nodes.StartEvents.BlankStartEvent{}), do: Nodes.StartEvents.BlankStartEvent
  defp node_module(%Nodes.StartEvents.MessageStartEvent{}), do: Nodes.StartEvents.MessageStartEvent
  defp node_module(%Nodes.StartEvents.SignalStartEvent{}), do: Nodes.StartEvents.SignalStartEvent
  defp node_module(%Nodes.StartEvents.TimerStartEvent{}), do: Nodes.StartEvents.TimerStartEvent
  defp node_module(%Nodes.EndEvents.BlankEndEvent{}), do: Nodes.EndEvents.BlankEndEvent
  defp node_module(%Nodes.EndEvents.ErrorEndEvent{}), do: Nodes.EndEvents.ErrorEndEvent
  defp node_module(%Nodes.EndEvents.MessageEndEvent{}), do: Nodes.EndEvents.MessageEndEvent
  defp node_module(%Nodes.EndEvents.SignalEndEvent{}), do: Nodes.EndEvents.SignalEndEvent
  defp node_module(%Nodes.EndEvents.EscalationEndEvent{}), do: Nodes.EndEvents.EscalationEndEvent
  defp node_module(%Nodes.EndEvents.TerminationEndEvent{}), do: Nodes.EndEvents.TerminationEndEvent
  defp node_module(%Nodes.IntermediateCatch.TimerEvent{}), do: Nodes.IntermediateCatch.TimerEvent
  defp node_module(%Nodes.IntermediateCatch.MessageEvent{}), do: Nodes.IntermediateCatch.MessageEvent
  defp node_module(%Nodes.IntermediateCatch.SignalEvent{}), do: Nodes.IntermediateCatch.SignalEvent
  defp node_module(%Nodes.IntermediateThrow.MessageEvent{}), do: Nodes.IntermediateThrow.MessageEvent
  defp node_module(%Nodes.IntermediateThrow.SignalEvent{}), do: Nodes.IntermediateThrow.SignalEvent
  defp node_module(%Nodes.IntermediateThrow.ErrorEvent{}), do: Nodes.IntermediateThrow.ErrorEvent
  defp node_module(%Nodes.IntermediateThrow.EscalationEvent{}), do: Nodes.IntermediateThrow.EscalationEvent
  defp node_module(_), do: nil

  # --- Handle NodeResult ---

  defp handle_node_result(state, token, result) do
    case result do
      {:next, next_node_id} ->
        token = Token.move_to(token, next_node_id)
        %{state | tokens: Map.put(state.tokens, token.id, token)}

      {:next_with_params, next_node_id, new_params} ->
        token = %{token | parameters: new_params}
        token = Token.move_to(token, next_node_id)
        %{state | tokens: Map.put(state.tokens, token.id, token)}

      {:fork, paths, _params} ->
        handle_fork(state, token, paths)

      {:wait_for_timer, timer_id, delay_ms} ->
        handle_wait_for_timer(state, token, timer_id, delay_ms)

      {:wait_for_message, name} ->
        handle_wait_for_message(state, token, name)

      {:wait_for_signal, name} ->
        handle_wait_for_signal(state, token, name)

      {:wait_for_script, ref} ->
        handle_wait_for_script(state, token, ref)

      {:wait_for_external_task, task_id, kind} ->
        handle_wait_for_external_task(state, token, task_id, kind)

      {:wait_for_call, child_id} ->
        handle_wait_for_call(state, token, child_id)

      {:wait_for_join} ->
        handle_wait_for_join(state, token)

      {:wait_for_expressions, ref} ->
        handle_wait_for_script(state, token, ref)

      {:wait_for_rules, ref} ->
        handle_wait_for_script(state, token, ref)

      {:complete, completion_data} ->
        handle_complete(state, token, completion_data)

      {:throw_message, name, payload, next_node} ->
        handle_throw_message(state, token, name, payload, next_node)

      {:throw_signal, name, next_node} ->
        handle_throw_signal(state, token, name, next_node)

      {:call, call_params} ->
        handle_call_activity(state, token, call_params)

      {:retry, backoff_ms} ->
        handle_retry(state, token, backoff_ms)

      {:step} ->
        handle_step(state, token)

      {:crash, error} ->
        Logger.error("Instance #{state.id}: Token #{token.id} crashed: #{inspect(error)}")
        crash_token(state, token)

      {:simulation_barrier_then_execute} ->
        %{state | tokens: Map.put(state.tokens, token.id, %{token | state: :execute_current_node})}

      {:simulation_barrier_then_wait, wait_type} ->
        token = Token.set_waiting(token, wait_type)
        move_to_waiting(state, token)

      _ ->
        Logger.warning("Instance #{state.id}: Unknown result: #{inspect(result)}")
        state
    end
  end

  # --- Result Handlers ---

  defp handle_fork(state, token, paths) do
    # Mark original token as joined
    token = Token.join(token)
    state = %{state |
      tokens: Map.put(state.tokens, token.id, token),
      active_tokens: MapSet.delete(state.active_tokens, token.id)
    }

    # Create new tokens for each path
    Enum.reduce(paths, state, fn path_node_id, acc ->
      {new_token, acc} = create_token(acc, token.family, path_node_id, token.parameters)
      %{acc | active_tokens: MapSet.put(acc.active_tokens, new_token.id)}
    end)
  end

  defp handle_wait_for_timer(state, token, timer_id, delay_ms) do
    token = token
      |> Token.set_waiting(:waiting_for_timer)
      |> Token.set_context(:intermediate_timer_id, timer_id)

    ref = Process.send_after(self(), {:timer_elapsed, token.id, make_ref()}, delay_ms)

    state = %{state | timer_refs: Map.put(state.timer_refs, ref, token.id)}

    # Persist timer created
    event = %PersistentData.TimerCreated{
      token: token.id, family: token.family, current_node: token.current_node,
      timer_id: timer_id, trigger_at: System.system_time(:millisecond) + delay_ms
    }
    state = append_event(state, event)

    move_to_waiting(state, token)
  end

  defp handle_wait_for_message(state, token, name) do
    token = Token.set_waiting(token, :waiting_for_message)
    waits = Map.update(state.message_waits, name, [token.id], &[token.id | &1])

    # Register in Registry for cross-instance routing
    Registry.register(:waits, {state.tenant_id, :message, name, state.business_key}, token.id)

    state = %{state | message_waits: waits}
    move_to_waiting(state, token)
  end

  defp handle_wait_for_signal(state, token, name) do
    token = Token.set_waiting(token, :waiting_for_signal)
    waits = Map.update(state.signal_waits, name, [token.id], &[token.id | &1])

    Registry.register(:waits, {state.tenant_id, :signal, name}, token.id)

    state = %{state | signal_waits: waits}
    move_to_waiting(state, token)
  end

  defp handle_wait_for_script(state, token, ref) do
    token = Token.set_waiting(token, :waiting_for_script)
    state = %{state |
      script_waits: Map.put(state.script_waits, ref, token.id),
      pin_state: :pinned,
      pin_reason: :script
    }
    move_to_waiting(state, token)
  end

  defp handle_wait_for_external_task(state, token, task_id, kind) do
    token = token
      |> Token.set_waiting(:waiting_for_external_task)
      |> Token.set_context(:external_task_id, task_id)

    state = %{state | external_tasks: Map.put(state.external_tasks, task_id, token.id)}

    # Persist external task creation
    event = %PersistentData.ExternalTaskCreation{
      token: token.id, family: token.family, current_node: token.current_node,
      external_task: task_id, retry_counter: token.context.retries
    }
    state = append_event(state, event)

    # Broadcast external task event for host handler
    node = Definition.get_node(state.definition, token.current_node)
    node_properties = if node, do: Map.get(node, :properties, %{}), else: %{}
    Phoenix.PubSub.broadcast(DryDev.Workflow.PubSub, "engine:events",
      {:external_task_created, state.id, state.business_key, state.tenant_id,
       task_id, kind, token.parameters, node && Map.get(node, :key), node_properties})

    move_to_waiting(state, token)
  end

  defp handle_wait_for_call(state, token, child_id) do
    token = Token.set_waiting(token, :waiting_for_call)
    state = %{state |
      call_wait_list: Map.put(state.call_wait_list, child_id, token.id),
      pin_state: :pinned,
      pin_reason: :call_start
    }
    move_to_waiting(state, token)
  end

  defp handle_wait_for_join(state, token) do
    token = Token.set_waiting(token, :waiting_for_join)
    node_id = token.current_node

    # Update joining list
    joining = Map.update(state.joining_list,
      {token.family, node_id},
      [token.id],
      &[token.id | &1]
    )

    state = %{state | joining_list: joining}

    # Check if join can complete
    _node = Definition.get_node(state.definition, node_id)
    inputs = Definition.get_inputs(state.definition, node_id)
    total_inputs = length(inputs)

    # Count recursive connections
    recursive_count = Enum.count(inputs, fn input_id ->
      Definition.is_recursive_connection?(state.definition, input_id, node_id)
    end)

    required = total_inputs - recursive_count
    arrived = length(Map.get(joining, {token.family, node_id}, []))

    if arrived >= required do
      # Join complete - resume first token, remove others
      [first | rest] = Map.get(joining, {token.family, node_id}, [])

      state = Enum.reduce(rest, state, fn tid, acc ->
        t = Map.get(acc.tokens, tid)
        if t do
          t = Token.join(t)
          %{acc |
            tokens: Map.put(acc.tokens, tid, t),
            waiting_tokens: MapSet.delete(acc.waiting_tokens, tid)
          }
        else
          acc
        end
      end)

      state = %{state | joining_list: Map.delete(state.joining_list, {token.family, node_id})}

      first_token = Map.get(state.tokens, first)
      if first_token do
        first_token = Token.continue(first_token)
        outputs = Definition.get_outputs(state.definition, node_id)
        first_output = List.first(outputs)
        first_token = if first_output, do: Token.move_to(first_token, first_output), else: first_token

        %{state |
          tokens: Map.put(state.tokens, first, first_token),
          waiting_tokens: MapSet.delete(state.waiting_tokens, first),
          active_tokens: MapSet.put(state.active_tokens, first)
        }
      else
        state
      end
    else
      move_to_waiting(state, token)
    end
  end

  defp handle_complete(state, token, completion_data) do
    token = token
      |> Token.complete()
      |> Token.set_context(:completion_data, completion_data)

    # Check for termination end event
    is_termination = match?(%DryDev.Workflow.Engine.CompletionData.Termination{}, completion_data)

    state = %{state |
      tokens: Map.put(state.tokens, token.id, token),
      active_tokens: MapSet.delete(state.active_tokens, token.id),
      completed_tokens: MapSet.put(state.completed_tokens, token.id)
    }

    if is_termination do
      # Terminate ALL active and waiting tokens
      terminate_all(state, completion_data.reason)
    else
      state
    end
  end

  defp handle_throw_message(state, token, name, payload, next_node) do
    # Persist message thrown
    event = %PersistentData.MessageThrown{
      token: token.id, family: token.family, current_node: token.current_node, name: name
    }
    state = append_event(state, event)

    # Broadcast message to other instances
    Phoenix.PubSub.broadcast(DryDev.Workflow.PubSub, "engine:messages",
      {:message, state.tenant_id, name, state.business_key, payload})

    # Advance token
    token = Token.move_to(token, next_node)
    %{state | tokens: Map.put(state.tokens, token.id, token)}
  end

  defp handle_throw_signal(state, token, name, next_node) do
    event = %PersistentData.SignalThrown{
      token: token.id, family: token.family, current_node: token.current_node, signal_name: name
    }
    state = append_event(state, event)

    Phoenix.PubSub.broadcast(DryDev.Workflow.PubSub, "engine:signals",
      {:signal, state.tenant_id, name})

    token = Token.move_to(token, next_node)
    %{state | tokens: Map.put(state.tokens, token.id, token)}
  end

  defp handle_call_activity(state, token, call_params) do
    child_id = UUID.uuid4()

    # Start child process instance
    case start_child_instance(state, token, call_params, child_id) do
      {:ok, _pid} ->
        event = %PersistentData.CallStarted{
          token: token.id, family: token.family, current_node: token.current_node,
          started_process: child_id, loop_index: call_params.loop_index
        }
        state = append_event(state, event)

        if call_params.async do
          # Async: advance immediately
          node = Definition.get_node(state.definition, token.current_node)
          first_output = List.first(Map.get(node, :outputs, []))
          token = Token.move_to(token, first_output)
          %{state | tokens: Map.put(state.tokens, token.id, token)}
        else
          # Sync: wait for child
          handle_wait_for_call(state, token, child_id)
        end

      {:error, reason} ->
        Logger.error("Instance #{state.id}: Failed to start child: #{inspect(reason)}")
        crash_token(state, token)
    end
  end

  defp handle_retry(state, token, backoff_ms) do
    token = Token.increment_retries(token)
    token = Token.set_waiting(token, :waiting_for_timer)

    ref = Process.send_after(self(), {:timer_elapsed, token.id, make_ref()}, backoff_ms)
    state = %{state | timer_refs: Map.put(state.timer_refs, ref, token.id)}

    move_to_waiting(state, token)
  end

  defp handle_step(state, token) do
    token = Token.increment_step(token)
    token = %{token | state: :execute_current_node}
    %{state | tokens: Map.put(state.tokens, token.id, token)}
  end

  # --- Helpers ---

  defp move_to_waiting(state, token) do
    %{state |
      tokens: Map.put(state.tokens, token.id, token),
      active_tokens: MapSet.delete(state.active_tokens, token.id),
      waiting_tokens: MapSet.put(state.waiting_tokens, token.id)
    }
  end

  defp crash_token(state, token) do
    token = Token.crash(token)
    %{state |
      tokens: Map.put(state.tokens, token.id, token),
      active_tokens: MapSet.delete(state.active_tokens, token.id)
    }
  end

  defp terminate_all(state, _reason) do
    Enum.reduce(state.tokens, state, fn {tid, t}, acc ->
      if Token.active?(t) or Token.waiting?(t) do
        t = Token.terminate(t)
        %{acc |
          tokens: Map.put(acc.tokens, tid, t),
          active_tokens: MapSet.delete(acc.active_tokens, tid),
          waiting_tokens: MapSet.delete(acc.waiting_tokens, tid)
        }
      else
        acc
      end
    end)
  end

  defp handle_error_in_activity(state, token, node, exception) do
    if Map.has_key?(node, :boundary_events) do
      boundary = DryDev.Workflow.Engine.Nodes.Activity.get_boundary_event_to_exception(node, exception)
      if boundary do
        interrupt_token_to_boundary(state, token, boundary)
      else
        crash_token(state, token)
      end
    else
      crash_token(state, token)
    end
  end

  defp interrupt_token_to_boundary(state, token, boundary) do
    output_path = DryDev.Workflow.Engine.Nodes.BoundaryEvents.output_path(boundary)
    if output_path do
      token = %{token | state: :execute_current_node, current_node: output_path}
      %{state | tokens: Map.put(state.tokens, token.id, token)}
    else
      crash_token(state, token)
    end
  end

  defp create_token(state, family, node_id, params) do
    token_id = state.next_token_id
    token = Token.new(token_id, family, node_id, params)
    state = %{state |
      tokens: Map.put(state.tokens, token_id, token),
      next_token_id: token_id + 1,
      token_families: MapSet.put(state.token_families, family)
    }
    {token, state}
  end

  defp append_event(state, event) do
    %{state | persistent_events: state.persistent_events ++ [event]}
  end

  defp start_child_instance(state, _token, call_params, child_id) do
    process_name = call_params.process_name
    tenant_id = call_params.tenant_id

    case DryDev.Workflow.Engine.Diagrams.DiagramStore.get_latest(process_name, tenant_id) do
      {:ok, definition} ->
        params = %{
          id: child_id,
          business_key: call_params.business_key,
          tenant_id: tenant_id,
          parent_id: state.id,
          parent_business_key: state.business_key,
          root_id: state.root_id,
          root_business_key: state.root_business_key,
          start_parameters: merge_call_params(call_params),
          started_by_engine: true
        }

        DynamicSupervisor.start_child(
          DryDev.Workflow.Engine.InstanceSupervisor,
          {DryDev.Workflow.Engine.Instance, {definition, params}}
        )

      {:error, :not_found} ->
        {:error, :process_not_found}
    end
  end

  defp merge_call_params(call_params) do
    params = call_params.parameters || %{}
    if call_params.element && call_params.element_name do
      Map.put(params, call_params.element_name, call_params.element)
    else
      params
    end
  end

  defp build_context(state, token, node) do
    %ExecutionContext{
      instance_id: state.id,
      instance_pid: self(),
      token: token,
      definition: state.definition,
      node: node,
      tenant_id: state.tenant_id,
      business_key: state.business_key,
      simulation_mode: state.instance_state == :simulating,
      simulation_events: state.persistent_events,
      simulation_index: 0
    }
  end
end
