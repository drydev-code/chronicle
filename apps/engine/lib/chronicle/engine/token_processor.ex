defmodule Chronicle.Engine.TokenProcessor do
  @moduledoc """
  Token update loop - pure functions called inside Instance GenServer.
  Processes active tokens and handles NodeResult outcomes.
  """

  alias Chronicle.Engine.{Token, ExecutionContext, PersistentData}
  alias Chronicle.Engine.Diagrams.Definition
  alias Chronicle.Engine.Instance.{BoundaryLifecycle, WaitRegistry}
  alias Chronicle.Engine.Nodes

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
  defp node_module(%Nodes.Tasks.ManualTask{}), do: Nodes.Tasks.ManualTask
  defp node_module(%Nodes.Tasks.SendTask{}), do: Nodes.Tasks.SendTask
  defp node_module(%Nodes.Tasks.ReceiveTask{}), do: Nodes.Tasks.ReceiveTask
  defp node_module(%Nodes.CallActivity{}), do: Nodes.CallActivity
  defp node_module(%Nodes.RulesTask{}), do: Nodes.RulesTask
  defp node_module(%Nodes.Gateway{}), do: Nodes.Gateway
  defp node_module(%Nodes.StartEvents.BlankStartEvent{}), do: Nodes.StartEvents.BlankStartEvent
  defp node_module(%Nodes.StartEvents.MessageStartEvent{}), do: Nodes.StartEvents.MessageStartEvent
  defp node_module(%Nodes.StartEvents.SignalStartEvent{}), do: Nodes.StartEvents.SignalStartEvent
  defp node_module(%Nodes.StartEvents.TimerStartEvent{}), do: Nodes.StartEvents.TimerStartEvent
  defp node_module(%Nodes.StartEvents.ConditionalStartEvent{}), do: Nodes.StartEvents.ConditionalStartEvent
  defp node_module(%Nodes.EndEvents.BlankEndEvent{}), do: Nodes.EndEvents.BlankEndEvent
  defp node_module(%Nodes.EndEvents.ErrorEndEvent{}), do: Nodes.EndEvents.ErrorEndEvent
  defp node_module(%Nodes.EndEvents.MessageEndEvent{}), do: Nodes.EndEvents.MessageEndEvent
  defp node_module(%Nodes.EndEvents.SignalEndEvent{}), do: Nodes.EndEvents.SignalEndEvent
  defp node_module(%Nodes.EndEvents.EscalationEndEvent{}), do: Nodes.EndEvents.EscalationEndEvent
  defp node_module(%Nodes.EndEvents.TerminationEndEvent{}), do: Nodes.EndEvents.TerminationEndEvent
  defp node_module(%Nodes.EndEvents.CompensationEndEvent{}), do: Nodes.EndEvents.CompensationEndEvent
  defp node_module(%Nodes.IntermediateCatch.TimerEvent{}), do: Nodes.IntermediateCatch.TimerEvent
  defp node_module(%Nodes.IntermediateCatch.MessageEvent{}), do: Nodes.IntermediateCatch.MessageEvent
  defp node_module(%Nodes.IntermediateCatch.SignalEvent{}), do: Nodes.IntermediateCatch.SignalEvent
  defp node_module(%Nodes.IntermediateCatch.ConditionalEvent{}), do: Nodes.IntermediateCatch.ConditionalEvent
  defp node_module(%Nodes.IntermediateCatch.LinkEvent{}), do: Nodes.IntermediateCatch.LinkEvent
  defp node_module(%Nodes.IntermediateThrow.MessageEvent{}), do: Nodes.IntermediateThrow.MessageEvent
  defp node_module(%Nodes.IntermediateThrow.SignalEvent{}), do: Nodes.IntermediateThrow.SignalEvent
  defp node_module(%Nodes.IntermediateThrow.ErrorEvent{}), do: Nodes.IntermediateThrow.ErrorEvent
  defp node_module(%Nodes.IntermediateThrow.EscalationEvent{}), do: Nodes.IntermediateThrow.EscalationEvent
  defp node_module(%Nodes.IntermediateThrow.LinkEvent{}), do: Nodes.IntermediateThrow.LinkEvent
  defp node_module(%Nodes.IntermediateThrow.CompensationEvent{}), do: Nodes.IntermediateThrow.CompensationEvent
  defp node_module(_), do: nil

  # --- Handle NodeResult ---

  defp handle_node_result(state, token, result) do
    case result do
      {:next, next_node_id} ->
        apply_loop_or_move(state, token, token.parameters, next_node_id)

      {:next_with_params, next_node_id, new_params} ->
        token = %{token | parameters: new_params}
        apply_loop_or_move(state, token, new_params, next_node_id)

      {:fork, paths, _params} ->
        handle_fork(state, token, paths)

      {:wait_for_timer, timer_id, delay_ms} ->
        handle_wait_for_timer(state, token, timer_id, delay_ms)

      {:wait_for_message, name} ->
        handle_wait_for_message(state, token, name)

      {:wait_for_signal, name} ->
        handle_wait_for_signal(state, token, name)

      {:wait_for_event_gateway, candidates} ->
        handle_wait_for_event_gateway(state, token, candidates)

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

      {:throw_compensation, next_node, complete?} ->
        handle_throw_compensation(state, token, next_node, complete?)

      {:traverse_link, link_name, target_node} ->
        handle_traverse_link(state, token, link_name, target_node)

      {:conditional_event_evaluated, condition, matched?, next_node} ->
        handle_conditional_event_evaluated(state, token, condition, matched?, next_node)

      {:event_gateway_resolved, trigger, selected_node, target_node} ->
        handle_event_gateway_resolved(state, token, trigger, selected_node, target_node)

      {:noop_task_completed, task_type, next_node} ->
        handle_noop_task_completed(state, token, task_type, next_node)

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
    state = append_event(state, %PersistentData.TokenFamilyRemoved{
      token: token.id,
      family: token.family,
      current_node: token.current_node
    })

    state = %{state |
      tokens: Map.put(state.tokens, token.id, token),
      active_tokens: MapSet.delete(state.active_tokens, token.id)
    }

    # Create new tokens for each path
    Enum.reduce(paths, state, fn path_node_id, acc ->
      {new_token, acc} = create_token(acc, token.family, path_node_id, token.parameters)
      acc = append_event(acc, %PersistentData.TokenFamilyCreated{
        token: new_token.id,
        family: new_token.family,
        current_node: new_token.current_node,
        start_params: new_token.parameters
      })
      %{acc | active_tokens: MapSet.put(acc.active_tokens, new_token.id)}
    end)
  end

  defp apply_loop_or_move(state, token, params, next_node_id) do
    node = Definition.get_node(state.definition, token.current_node)
    state = record_compensatable_completion(state, token, node)

    case loop_characteristics(node) do
      nil ->
        token = Token.move_to(token, next_node_id)
        %{state | tokens: Map.put(state.tokens, token.id, token)}

      loop ->
        iteration = loop_iteration(token, node.id) + 1
        continue? = loop_continue?(loop, params, iteration, node.id)
        target_node = if continue?, do: node.id, else: next_node_id

        event = %PersistentData.LoopConditionEvaluated{
          token: token.id,
          family: token.family,
          current_node: token.current_node,
          condition: Map.get(loop, "condition"),
          iteration: iteration,
          continue: continue?,
          max_iterations: Map.get(loop, "maxIterations"),
          target_node: target_node,
          evaluated_at: System.system_time(:millisecond)
        }

        token =
          token
          |> put_loop_iteration(node.id, iteration)
          |> Token.move_to(target_node)

        state
        |> append_event(event)
        |> Map.update!(:tokens, &Map.put(&1, token.id, token))
    end
  end

  defp loop_characteristics(%{properties: %{"loopCharacteristics" => loop}}) when is_map(loop) do
    if activity_node_with_loop?(loop), do: loop
  end

  defp loop_characteristics(_), do: nil

  defp activity_node_with_loop?(%{"testBefore" => true}), do: false
  defp activity_node_with_loop?(_), do: true

  defp loop_iteration(token, node_id) do
    token.context
    |> Map.get(:loop_iterations, %{})
    |> Map.get(node_id, 0)
  end

  defp put_loop_iteration(token, node_id, iteration) do
    iterations = Map.put(Map.get(token.context, :loop_iterations, %{}), node_id, iteration)
    Token.set_context(token, :loop_iterations, iterations)
  end

  defp loop_continue?(loop, params, iteration, node_id) do
    max_iterations = Map.get(loop, "maxIterations")

    cond do
      is_integer(max_iterations) and iteration >= max_iterations ->
        false

      condition = Map.get(loop, "condition") ->
        params =
          params
          |> Map.put("loopIteration", iteration)
          |> Map.put(:loop_iteration, iteration)

        case Chronicle.Engine.Scripting.ScriptPool.evaluate_expressions([{node_id, condition}], params) do
          {:ok, results} -> expression_true?(results, node_id)
          _ -> false
        end

      true ->
        false
    end
  end

  defp expression_true?(results, node_id) when is_list(results) do
    Enum.any?(results, fn
      %{"node_id" => ^node_id, "result" => true} -> true
      %{node_id: ^node_id, result: true} -> true
      {^node_id, true} -> true
      true -> true
      _ -> false
    end)
  end

  defp expression_true?(true, _node_id), do: true
  defp expression_true?(_, _node_id), do: false

  defp record_compensatable_completion(state, token, node) do
    compensation_boundaries =
      (Map.get(node || %{}, :boundary_events) || [])
      |> Enum.filter(&match?(%Chronicle.Engine.Nodes.BoundaryEvents.CompensationBoundary{}, &1))

    Enum.reduce(compensation_boundaries, state, fn boundary, acc ->
      handler_node_id = Chronicle.Engine.Nodes.BoundaryEvents.output_path(boundary)
      activity_key = "#{token.id}:#{node.id}:#{loop_iteration(token, node.id)}"

      events = [
        %PersistentData.CompensationHandlerRegistered{
          token: token.id,
          family: token.family,
          current_node: token.current_node,
          boundary_node_id: boundary.id,
          handler_node_id: handler_node_id
        },
        %PersistentData.CompensatableActivityCompleted{
          token: token.id,
          family: token.family,
          current_node: token.current_node,
          activity_node_id: node.id,
          handler_node_id: handler_node_id,
          activity_instance_key: activity_key
        }
      ]

      activity = %{
        token: token.id,
        family: token.family,
        activity_node_id: node.id,
        handler_node_id: handler_node_id,
        activity_instance_key: activity_key
      }

      acc
      |> append_events(events)
      |> Map.update!(:compensatable_activities, &Map.put(&1, activity_key, activity))
    end)
  end

  defp handle_throw_compensation(state, token, next_node, complete?) do
    eligible =
      state.compensatable_activities
      |> Map.values()
      |> Enum.reject(&MapSet.member?(state.compensation_started || MapSet.new(), &1.activity_instance_key))
      |> Enum.sort_by(& &1.activity_instance_key)

    request_event = %PersistentData.CompensationRequested{
      token: token.id,
      family: token.family,
      current_node: token.current_node,
      eligible_activity_keys: Enum.map(eligible, & &1.activity_instance_key),
      requested_at: System.system_time(:millisecond)
    }

    {state, _started} =
      Enum.reduce(eligible, {append_event(state, request_event), MapSet.new()}, fn activity, {acc, started} ->
        {handler_token, acc} = create_token(acc, token.family, activity.handler_node_id, token.parameters)
        handler_token =
          handler_token
          |> Token.set_context(:compensation_activity_key, activity.activity_instance_key)
          |> Token.set_context(:compensation_handler_node_id, activity.handler_node_id)

        acc = %{acc | tokens: Map.put(acc.tokens, handler_token.id, handler_token)}

        event = %PersistentData.CompensationHandlerStarted{
          token: token.id,
          family: token.family,
          current_node: token.current_node,
          activity_instance_key: activity.activity_instance_key,
          handler_node_id: activity.handler_node_id,
          handler_token: handler_token.id
        }

        acc =
          acc
          |> append_event(event)
          |> Map.update!(:active_tokens, &MapSet.put(&1, handler_token.id))
          |> Map.update!(:compensation_started, &MapSet.put(&1, activity.activity_instance_key))

        {acc, MapSet.put(started, activity.activity_instance_key)}
      end)

    if complete? do
      handle_complete(state, token, %Chronicle.Engine.CompletionData.Blank{})
    else
      apply_loop_or_move(state, token, token.parameters, next_node)
    end
  end

  defp handle_wait_for_timer(state, token, timer_id, delay_ms) do
    token = token
      |> Token.set_waiting(:waiting_for_timer)
      |> Token.set_context(:intermediate_timer_id, timer_id)

    ref = Process.send_after(self(), {:timer_elapsed, token.id, timer_id}, delay_ms)

    state = %{state |
      timer_refs: Map.put(state.timer_refs, ref, token.id),
      timer_ref_ids: Map.put(state.timer_ref_ids || %{}, ref, timer_id)
    }

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

    event = %PersistentData.MessageWaitCreated{
      token: token.id,
      family: token.family,
      current_node: token.current_node,
      name: name,
      business_key: state.business_key
    }

    state = state |> append_event(event) |> Map.put(:message_waits, waits)
    move_to_waiting(state, token)
  end

  defp handle_wait_for_signal(state, token, name) do
    token = Token.set_waiting(token, :waiting_for_signal)
    waits = Map.update(state.signal_waits, name, [token.id], &[token.id | &1])

    Registry.register(:waits, {state.tenant_id, :signal, name}, token.id)

    event = %PersistentData.SignalWaitCreated{
      token: token.id,
      family: token.family,
      current_node: token.current_node,
      signal_name: name
    }

    state = state |> append_event(event) |> Map.put(:signal_waits, waits)
    move_to_waiting(state, token)
  end

  defp handle_wait_for_event_gateway(state, token, candidates) do
    token =
      token
      |> Token.set_waiting(:waiting_for_event_gateway)
      |> Token.set_context(:event_gateway_candidates, candidates)

    {state, message_names, signal_names, timer_ids, trigger_at_by_timer_id} =
      Enum.reduce(candidates, {state, [], [], [], %{}}, fn candidate, {acc, msgs, sigs, timers, triggers} ->
        case candidate do
          %{type: :message, name: name} when not is_nil(name) ->
            waits = Map.update(acc.message_waits, name, [token.id], &[token.id | &1])
            Registry.register(:waits, {acc.tenant_id, :message, name, acc.business_key}, token.id)
            {%{acc | message_waits: waits}, [name | msgs], sigs, timers, triggers}

          %{type: :signal, name: name} when not is_nil(name) ->
            waits = Map.update(acc.signal_waits, name, [token.id], &[token.id | &1])
            Registry.register(:waits, {acc.tenant_id, :signal, name}, token.id)
            {%{acc | signal_waits: waits}, msgs, [name | sigs], timers, triggers}

          %{type: :timer, timer_config: timer_config} ->
            timer_id = UUID.uuid4()
            delay_ms = compute_timer_delay(timer_config)
            ref = Process.send_after(self(), {:timer_elapsed, token.id, timer_id}, delay_ms)
            trigger_at = System.system_time(:millisecond) + delay_ms

            timer_event = %PersistentData.TimerCreated{
              token: token.id,
              family: token.family,
              current_node: token.current_node,
              timer_id: timer_id,
              trigger_at: trigger_at,
              target_node: token.current_node
            }

            acc =
              acc
              |> append_event(timer_event)
              |> Map.update!(:timer_refs, &Map.put(&1, ref, token.id))
              |> Map.update(:timer_ref_ids, %{ref => timer_id}, &Map.put(&1, ref, timer_id))

            {acc, msgs, sigs, [timer_id | timers], Map.put(triggers, timer_id, trigger_at)}

          _ ->
            {acc, msgs, sigs, timers, triggers}
        end
      end)

    event = %PersistentData.EventGatewayActivated{
      token: token.id,
      family: token.family,
      current_node: token.current_node,
      message_names: Enum.reverse(message_names),
      signal_names: Enum.reverse(signal_names),
      timer_ids: Enum.reverse(timer_ids),
      trigger_at_by_timer_id: trigger_at_by_timer_id
    }

    token = Token.set_context(token, :event_gateway_timer_ids, Enum.reverse(timer_ids))
    state = append_event(state, event)
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

    node = Definition.get_node(state.definition, token.current_node)
    node_properties = if node, do: Map.get(node, :properties, %{}), else: %{}
    actor_type = Map.get(node_properties, "actorType") || Map.get(node_properties, :actorType)

    # Persist external task creation
    event = %PersistentData.ExternalTaskCreation{
      token: token.id, family: token.family, current_node: token.current_node,
      external_task: task_id, retry_counter: token.context.retries,
      actor_type: actor_type
    }
    state = append_event(state, event)

    state = enqueue_effect(state, {:pubsub, "engine:events",
      {:external_task_created, state.id, state.business_key, state.tenant_id,
       task_id, kind, token.parameters, node && Map.get(node, :key), node_properties}})

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
    node = Definition.get_node(state.definition, node_id)
    arrived_token_ids = Map.get(joining, {token.family, node_id}, [])
    arrived = length(arrived_token_ids)

    required =
      case node do
        %Chronicle.Engine.Nodes.Gateway{kind: :inclusive} ->
          inclusive_join_required(state, token, node_id, arrived_token_ids)

        _ ->
          inputs = Definition.get_inputs(state.definition, node_id)
          total_inputs = length(inputs)

          # Count recursive connections
          recursive_count = Enum.count(inputs, fn input_id ->
            Definition.is_recursive_connection?(state.definition, input_id, node_id)
          end)

          total_inputs - recursive_count
      end

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
    state =
      case token.context[:compensation_activity_key] do
        nil ->
          state

        activity_key ->
          append_event(state, %PersistentData.CompensationHandlerCompleted{
            token: token.id,
            family: token.family,
            current_node: token.current_node,
            activity_instance_key: activity_key,
            handler_node_id: token.context[:compensation_handler_node_id]
          })
      end

    token = token
      |> Token.complete()
      |> Token.set_context(:completion_data, completion_data)

    # Check for termination end event
    is_termination = match?(%Chronicle.Engine.CompletionData.Termination{}, completion_data)

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

    state = enqueue_effect(state, {:pubsub, "engine:messages",
      {:message, state.tenant_id, name, state.business_key, payload}})

    apply_loop_or_move(state, token, token.parameters, next_node)
  end

  defp handle_throw_signal(state, token, name, next_node) do
    event = %PersistentData.SignalThrown{
      token: token.id, family: token.family, current_node: token.current_node, signal_name: name
    }
    state = append_event(state, event)

    state = enqueue_effect(state, {:pubsub, "engine:signals", {:signal, state.tenant_id, name}})

    apply_loop_or_move(state, token, token.parameters, next_node)
  end

  defp handle_traverse_link(state, token, link_name, target_node) do
    event = %PersistentData.LinkTraversed{
      token: token.id,
      family: token.family,
      current_node: token.current_node,
      link_name: link_name,
      target_node: target_node
    }

    state = append_event(state, event)
    token = Token.move_to(token, target_node)
    %{state | tokens: Map.put(state.tokens, token.id, token)}
  end

  defp handle_conditional_event_evaluated(state, token, condition, true, next_node) do
    event = %PersistentData.ConditionalEventEvaluated{
      token: token.id,
      family: token.family,
      current_node: token.current_node,
      condition: condition,
      matched: true,
      target_node: next_node,
      evaluated_at: System.system_time(:millisecond)
    }

    state = append_event(state, event)
    apply_loop_or_move(state, token, token.parameters, next_node)
  end

  defp handle_conditional_event_evaluated(state, token, condition, false, _next_node) do
    event = %PersistentData.ConditionalEventEvaluated{
      token: token.id,
      family: token.family,
      current_node: token.current_node,
      condition: condition,
      matched: false,
      evaluated_at: System.system_time(:millisecond)
    }

    state = append_event(state, event)
    token = Token.set_waiting(token, :waiting_for_conditional_event)

    wait_event = %PersistentData.ConditionalEventWaitCreated{
      token: token.id,
      family: token.family,
      current_node: token.current_node,
      condition: condition,
      condition_key: nil
    }

    state = append_event(state, wait_event)
    move_to_waiting(state, token)
  end

  defp handle_event_gateway_resolved(state, token, trigger, selected_node, target_node) do
    state = remove_event_gateway_waits(state, token)
    {state, canceled_timer_ids} = cancel_timer_refs_for_token(state, token.id)

    {trigger_type, trigger_name, payload} =
      case trigger do
        {:message, name, payload} -> {:message, name, payload}
        {:signal, name} -> {:signal, name, nil}
        :timer_elapsed -> {:timer, nil, nil}
        _ -> {:unknown, nil, nil}
      end

    state =
      canceled_timer_ids
      |> Enum.reduce(state, fn timer_id, acc ->
        append_event(acc, %PersistentData.TimerCanceled{
          token: token.id,
          family: token.family,
          current_node: token.current_node,
          target_node: target_node,
          retry_counter: token.context[:retries],
          timer_id: timer_id
        })
      end)

    event = %PersistentData.EventGatewayResolved{
      token: token.id,
      family: token.family,
      current_node: token.current_node,
      trigger_type: trigger_type,
      trigger_name: trigger_name,
      selected_node: selected_node,
      target_node: target_node,
      payload: payload,
      triggered_at: System.system_time(:millisecond)
    }

    state = append_event(state, event)
    token = Token.move_to(token, target_node)
    %{state | tokens: Map.put(state.tokens, token.id, token)}
  end

  defp handle_noop_task_completed(state, token, task_type, next_node) do
    event = %PersistentData.NoOpTaskCompleted{
      token: token.id,
      family: token.family,
      current_node: token.current_node,
      task_type: task_type,
      target_node: next_node
    }

    state = append_event(state, event)
    apply_loop_or_move(state, token, token.parameters, next_node)
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

    timer_id = "retry:#{token.id}:#{System.unique_integer([:positive])}"
    ref = Process.send_after(self(), {:timer_elapsed, token.id, timer_id}, backoff_ms)
    state = %{state |
      timer_refs: Map.put(state.timer_refs, ref, token.id),
      timer_ref_ids: Map.put(state.timer_ref_ids || %{}, ref, timer_id)
    }

    state = append_event(state, %PersistentData.TimerCreated{
      token: token.id,
      family: token.family,
      current_node: token.current_node,
      timer_id: timer_id,
      trigger_at: System.system_time(:millisecond) + backoff_ms
    })

    move_to_waiting(state, token)
  end

  defp handle_step(state, token) do
    token = Token.increment_step(token)
    token = %{token | state: :execute_current_node}
    %{state | tokens: Map.put(state.tokens, token.id, token)}
  end

  # --- Helpers ---

  defp move_to_waiting(state, token) do
    state = register_boundary_events(state, token)

    %{state |
      tokens: Map.put(state.tokens, token.id, token),
      active_tokens: MapSet.delete(state.active_tokens, token.id),
      waiting_tokens: MapSet.put(state.waiting_tokens, token.id)
    }
  end

  defp crash_token(state, token) do
    events = BoundaryLifecycle.cancellation_events(state, token.id)
    state = Enum.reduce(events, state, &append_event(&2, &1))
    state = WaitRegistry.cancel_boundary_registrations(state, token.id)

    token = Token.crash(token)
    %{state |
      tokens: Map.put(state.tokens, token.id, token),
      active_tokens: MapSet.delete(state.active_tokens, token.id)
    }
  end

  defp terminate_all(state, _reason) do
    state =
      state.boundary_index
      |> Map.keys()
      |> Enum.reduce(state, fn token_id, acc ->
        events = BoundaryLifecycle.cancellation_events(acc, token_id)
        acc = Enum.reduce(events, acc, &append_event(&2, &1))
        WaitRegistry.cancel_boundary_registrations(acc, token_id)
      end)

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

  defp inclusive_join_required(state, token, join_node_id, arrived_token_ids) do
    arrived_set = MapSet.new(arrived_token_ids)

    other_reachable =
      state.tokens
      |> Enum.reject(fn {tid, _t} -> MapSet.member?(arrived_set, tid) end)
      |> Enum.count(fn {_tid, other} ->
        other.family == token.family and
          not Token.terminal?(other) and
          can_reach?(state.definition, other.current_node, join_node_id)
      end)

    length(arrived_token_ids) + other_reachable
  end

  defp can_reach?(_definition, node_id, node_id), do: true

  defp can_reach?(definition, from_node_id, target_node_id) do
    do_can_reach?(definition, [from_node_id], target_node_id, MapSet.new())
  end

  defp do_can_reach?(_definition, [], _target_node_id, _seen), do: false

  defp do_can_reach?(definition, [node_id | rest], target_node_id, seen) do
    cond do
      node_id == target_node_id ->
        true

      MapSet.member?(seen, node_id) ->
        do_can_reach?(definition, rest, target_node_id, seen)

      true ->
        next =
          definition
          |> Definition.get_outputs(node_id)
          |> Enum.reject(&Definition.is_recursive_connection?(definition, node_id, &1))

        do_can_reach?(definition, rest ++ next, target_node_id, MapSet.put(seen, node_id))
    end
  end

  defp handle_error_in_activity(state, token, node, exception) do
    if Map.has_key?(node, :boundary_events) do
      boundary = Chronicle.Engine.Nodes.Activity.get_boundary_event_to_exception(node, exception)
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
    output_path = Chronicle.Engine.Nodes.BoundaryEvents.output_path(boundary)
    if output_path do
      trigger = BoundaryLifecycle.trigger_event(state, token.id, boundary.id)
      cancellations = BoundaryLifecycle.cancellation_events(state, token.id, boundary.id)

      state =
        [trigger | cancellations]
        |> Enum.reduce(state, &append_event(&2, &1))
        |> WaitRegistry.cancel_boundary_registrations(token.id)

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

  defp register_boundary_events(state, token) do
    if Map.has_key?(state.boundary_index || %{}, token.id) do
      state
    else
      node = Definition.get_node(state.definition, token.current_node)
      boundaries =
        (Map.get(node || %{}, :boundary_events, []) || [])
        |> Enum.reject(&match?(%Chronicle.Engine.Nodes.BoundaryEvents.CompensationBoundary{}, &1))

      Enum.reduce(boundaries, %{state | boundary_index: Map.put(state.boundary_index || %{}, token.id, [])}, fn boundary, acc ->
        {acc, info} = register_boundary_event(acc, token, boundary)
        update_in(acc.boundary_index[token.id], &[info | (&1 || [])])
      end)
    end
  end

  defp register_boundary_event(state, token, boundary) do
    interrupting? = Chronicle.Engine.Nodes.BoundaryEvents.interrupting?(boundary)
    type = boundary_type(boundary)

    {state, info} =
      case type do
        :timer ->
          delay_ms = Chronicle.Engine.Nodes.BoundaryEvents.compute_timer_delay(boundary, token.parameters)
          timer_id = "boundary:#{token.id}:#{boundary.id}:#{System.unique_integer([:positive])}"
          trigger_at = System.system_time(:millisecond) + delay_ms
          ref = Process.send_after(self(), {:boundary_timer_elapsed, token.id, boundary.id, timer_id}, delay_ms)

          state = %{state |
            timer_refs: Map.put(state.timer_refs, ref, token.id),
            timer_ref_ids: Map.put(state.timer_ref_ids || %{}, ref, timer_id)
          }
          {state, %{type: type, boundary_node_id: boundary.id, timer_id: timer_id, timer_ref: ref, name: nil, interrupting: interrupting?, trigger_at: trigger_at}}

        :message ->
          name = resolve_message_name(Map.get(boundary, :message), token.parameters)
          Registry.register(:waits, {state.tenant_id, :message, name, state.business_key}, {:boundary, token.id, boundary.id})
          target = if interrupting?, do: :message_boundaries, else: :ni_message_boundaries
          state = Map.update!(state, target, fn waits ->
            Map.update(waits, name, [{token.id, boundary}], &[{token.id, boundary} | &1])
          end)
          {state, %{type: type, boundary_node_id: boundary.id, timer_id: nil, timer_ref: nil, name: name, interrupting: interrupting?, trigger_at: nil}}

        :signal ->
          name = Map.get(boundary, :signal)
          Registry.register(:waits, {state.tenant_id, :signal, name}, {:boundary, token.id, boundary.id})
          target = if interrupting?, do: :signal_boundaries, else: :ni_signal_boundaries
          state = Map.update!(state, target, fn waits ->
            Map.update(waits, name, [{token.id, boundary}], &[{token.id, boundary} | &1])
          end)
          {state, %{type: type, boundary_node_id: boundary.id, timer_id: nil, timer_ref: nil, name: name, interrupting: interrupting?, trigger_at: nil}}

        :conditional ->
          condition = Map.get(boundary, :condition)
          {state, %{type: type, boundary_node_id: boundary.id, timer_id: nil, timer_ref: nil, name: nil, condition: condition, interrupting: interrupting?, trigger_at: nil}}

        _ ->
          {state, %{type: type, boundary_node_id: boundary.id, timer_id: nil, timer_ref: nil, name: nil, interrupting: interrupting?, trigger_at: nil}}
      end

    event = %PersistentData.BoundaryEventCreated{
      token: token.id,
      family: token.family,
      current_node: token.current_node,
      boundary_node_id: boundary.id,
      boundary_type: type,
      interrupting: interrupting?,
      name: info.name,
      condition: Map.get(info, :condition),
      timer_id: info.timer_id,
      trigger_at: info.trigger_at
    }

    {append_event(state, event), info}
  end

  defp boundary_type(%Chronicle.Engine.Nodes.BoundaryEvents.TimerBoundary{}), do: :timer
  defp boundary_type(%Chronicle.Engine.Nodes.BoundaryEvents.NonInterruptingTimerBoundary{}), do: :timer
  defp boundary_type(%Chronicle.Engine.Nodes.BoundaryEvents.MessageBoundary{}), do: :message
  defp boundary_type(%Chronicle.Engine.Nodes.BoundaryEvents.NonInterruptingMessageBoundary{}), do: :message
  defp boundary_type(%Chronicle.Engine.Nodes.BoundaryEvents.SignalBoundary{}), do: :signal
  defp boundary_type(%Chronicle.Engine.Nodes.BoundaryEvents.NonInterruptingSignalBoundary{}), do: :signal
  defp boundary_type(%Chronicle.Engine.Nodes.BoundaryEvents.ConditionalBoundary{}), do: :conditional
  defp boundary_type(%Chronicle.Engine.Nodes.BoundaryEvents.NonInterruptingConditionalBoundary{}), do: :conditional
  defp boundary_type(%Chronicle.Engine.Nodes.BoundaryEvents.CompensationBoundary{}), do: :compensation
  defp boundary_type(%Chronicle.Engine.Nodes.BoundaryEvents.ErrorBoundary{}), do: :error
  defp boundary_type(%Chronicle.Engine.Nodes.BoundaryEvents.EscalationBoundary{}), do: :escalation
  defp boundary_type(_), do: :unknown

  defp resolve_message_name(%{static_text: text, variable_content: var}, params) when not is_nil(var) do
    variable_value = Map.get(params, var, "")
    "#{text}##{variable_value}"
  end
  defp resolve_message_name(%{name: name}, _params), do: name
  defp resolve_message_name(name, _params) when is_binary(name), do: name
  defp resolve_message_name(_, _params), do: nil

  defp compute_timer_delay(%{duration_ms: ms}) when is_integer(ms), do: ms
  defp compute_timer_delay(%{period: %{hours: h, minutes: m, seconds: s}}) do
    (h || 0) * 3_600_000 + (m || 0) * 60_000 + (s || 0) * 1000
  end
  defp compute_timer_delay(_), do: 1000

  defp remove_event_gateway_waits(state, token) do
    candidates = token.context[:event_gateway_candidates] || []

    Enum.reduce(candidates, state, fn
      %{type: :message, name: name}, acc ->
        key = {acc.tenant_id, :message, name, acc.business_key}
        Registry.unregister_match(:waits, key, token.id)

        waits =
          acc.message_waits
          |> remove_token_wait(name, token.id)

        %{acc | message_waits: waits}

      %{type: :signal, name: name}, acc ->
        key = {acc.tenant_id, :signal, name}
        Registry.unregister_match(:waits, key, token.id)

        waits =
          acc.signal_waits
          |> remove_token_wait(name, token.id)

        %{acc | signal_waits: waits}

      _candidate, acc ->
        acc
    end)
  end

  def cancel_timer_refs_for_token(state, token_id) do
    {refs, keep_refs} =
      Enum.split_with(state.timer_refs || %{}, fn {_ref, owner_token_id} ->
        owner_token_id == token_id
      end)

    Enum.each(refs, fn {ref, _token_id} -> Process.cancel_timer(ref) end)

    canceled_timer_ids =
      refs
      |> Enum.map(fn {ref, _token_id} -> Map.get(state.timer_ref_ids || %{}, ref) end)
      |> Enum.reject(&is_nil/1)

    keep_ref_ids = Map.drop(state.timer_ref_ids || %{}, Enum.map(refs, &elem(&1, 0)))

    {%{state | timer_refs: Map.new(keep_refs), timer_ref_ids: keep_ref_ids}, canceled_timer_ids}
  end

  defp remove_token_wait(waits, name, token_id) do
    updated =
      waits
      |> Map.get(name, [])
      |> List.delete(token_id)

    if updated == [] do
      Map.delete(waits, name)
    else
      Map.put(waits, name, updated)
    end
  end

  defp append_event(state, event) do
    %{state | persistent_events: state.persistent_events ++ [event]}
  end

  defp append_events(state, events) do
    %{state | persistent_events: state.persistent_events ++ events}
  end

  defp enqueue_effect(state, effect) do
    %{state | pending_effects: (state.pending_effects || []) ++ [effect]}
  end

  defp start_child_instance(state, _token, call_params, child_id) do
    process_name = call_params.process_name
    tenant_id = call_params.tenant_id

    case Chronicle.Engine.Diagrams.DiagramStore.get_latest(process_name, tenant_id) do
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
          Chronicle.Engine.InstanceSupervisor,
          {Chronicle.Engine.Instance, {definition, params}}
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
