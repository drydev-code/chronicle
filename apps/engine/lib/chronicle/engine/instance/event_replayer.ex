defmodule Chronicle.Engine.Instance.EventReplayer do
  @moduledoc """
  Pure functions for replaying persistent events to restore instance state.
  Walks through event history and rebuilds token positions, wait states,
  and open tasks/timers/waits from the event log.
  """

  require Logger

  alias Chronicle.Engine.{Token, PersistentData}
  alias Chronicle.Engine.Diagrams.DiagramStore
  alias Chronicle.Engine.Instance.TokenState

  @doc """
  Restores a full instance state from persistent events.
  Finds the start event, loads the definition, replays all events,
  and finalizes the restored state. Returns {:ok, state} or {:error, reason}.
  """
  def restore_from_events(events, state) do
    start_event = Enum.find(events, fn
      %PersistentData.ProcessInstanceStart{} -> true
      _ -> false
    end)

    if start_event == nil do
      Logger.error("Instance #{state.id}: No ProcessInstanceStart event found in history")
      {:error, :no_start_event}
    else
      process_name = start_event.process_name
      process_version = start_event.process_version
      tenant_id = start_event.tenant || state.tenant_id

      case DiagramStore.get(process_name, process_version, tenant_id) do
        {:ok, definition} ->
          state = %{state |
            business_key: start_event.business_key,
            tenant_id: tenant_id,
            definition: definition,
            parent_id: start_event.parent_id,
            parent_business_key: start_event.parent_business_key,
            root_id: start_event.root_id || state.id,
            root_business_key: start_event.root_business_key || start_event.business_key,
            start_parameters: start_event.start_parameters || %{},
            start_node_id: start_event.start_node_id
          }

          state = replay_events(events, state)
          state = finalize_restored_state(state)

          {:ok, state}

        {:error, :not_found} ->
          Logger.error(
            "Instance #{state.id}: Definition '#{process_name}' version #{inspect(process_version)} " <>
              "not found for tenant #{tenant_id}; refusing to fall back to latest to preserve replay fidelity"
          )
          {:error, {:definition_version_not_found, process_name, process_version}}

        {:loading, _key} ->
          Logger.error(
            "Instance #{state.id}: Definition '#{process_name}' version #{inspect(process_version)} " <>
              "is registered but not yet loaded"
          )
          {:error, {:definition_not_loaded, process_name, process_version}}

        _ ->
          Logger.error(
            "Instance #{state.id}: Failed to load definition '#{process_name}' version #{inspect(process_version)}"
          )
          {:error, {:definition_load_failed, process_name, process_version}}
      end
    end
  end

  # Replays all events against the given state, returning the fully
  # reconstructed state with tokens, waits, and timers restored.
  defp replay_events(events, state) do
    acc = %{
      state: state,
      token_wait_states: %{},
      open_external_tasks: %{},
      open_timers: %{},
      open_message_waits: %{},
      open_signal_waits: %{},
      open_message_boundaries: %{},
      open_signal_boundaries: %{},
      open_ni_message_boundaries: %{},
      open_ni_signal_boundaries: %{},
      open_call_waits: %{},
      max_token_id: -1
    }

    acc = Enum.reduce(events, acc, &replay_single_event/2)

    # Apply accumulated state back
    state = acc.state
    state = %{state |
      external_tasks: acc.open_external_tasks,
      message_waits: acc.open_message_waits,
      signal_waits: acc.open_signal_waits,
      message_boundaries: acc.open_message_boundaries,
      signal_boundaries: acc.open_signal_boundaries,
      ni_message_boundaries: acc.open_ni_message_boundaries,
      ni_signal_boundaries: acc.open_ni_signal_boundaries,
      call_wait_list: acc.open_call_waits,
      next_token_id: acc.max_token_id + 1
    }

    # Detect message/signal waits from definition for tokens without explicit wait events
    {state, token_wait_states, open_message_waits, open_signal_waits} =
      detect_implicit_waits(state, acc.token_wait_states, acc.open_message_waits, acc.open_signal_waits)

    # Apply the final message/signal waits (including implicit ones) back to state
    state = %{state | message_waits: open_message_waits, signal_waits: open_signal_waits}

    # Classify tokens into active/waiting/completed sets
    state = TokenState.classify_tokens(state, token_wait_states)

    # Re-register timers for tokens still waiting
    state = reregister_timers(state, acc.open_timers)

    # Re-register message/signal waits in the Registry for cross-instance routing
    reregister_waits_in_registry(state, open_message_waits, open_signal_waits)
    reregister_boundaries_in_registry(state)

    state
  end

  # --- Event replay clauses ---

  defp replay_single_event(%PersistentData.ProcessInstanceStart{}, acc) do
    acc
  end

  defp replay_single_event(%PersistentData.TokenFamilyCreated{} = event, acc) do
    state = acc.state
    token_id = event.token
    family = event.family
    node_id = event.current_node
    params = event.start_params || %{}

    token = Token.new(token_id, family, node_id, params)

    state = %{state |
      tokens: Map.put(state.tokens, token_id, token),
      token_families: MapSet.put(state.token_families, family)
    }

    max_id = max(acc.max_token_id, token_id)
    %{acc | state: state, max_token_id: max_id}
  end

  defp replay_single_event(%PersistentData.TokenFamilyRemoved{} = event, acc) do
    state = acc.state
    state = %{state | token_families: MapSet.delete(state.token_families, event.family)}
    %{acc | state: state}
  end

  defp replay_single_event(%PersistentData.ExternalTaskCreation{} = event, acc) do
    state = acc.state
    token_id = event.token
    task_id = event.external_task

    state = TokenState.update_token_node(state, token_id, event.current_node)
    state = TokenState.update_token_context(state, token_id, :external_task_id, task_id)
    state = TokenState.set_token_wait_state(state, token_id, :waiting_for_external_task)

    acc = %{acc |
      state: state,
      open_external_tasks: Map.put(acc.open_external_tasks, task_id, token_id),
      token_wait_states: Map.put(acc.token_wait_states, token_id, :waiting_for_external_task)
    }
    track_token_id(acc, token_id)
  end

  defp replay_single_event(%PersistentData.ExternalTaskCompletion{} = event, acc) do
    state = acc.state
    token_id = event.token
    task_id = event.external_task

    acc = %{acc | open_external_tasks: Map.delete(acc.open_external_tasks, task_id)}

    state = if event.next_node do
      TokenState.update_token_node(state, token_id, event.next_node)
    else
      state
    end

    state = TokenState.set_token_active(state, token_id)
    acc = %{acc |
      state: state,
      token_wait_states: Map.delete(acc.token_wait_states, token_id)
    }
    track_token_id(acc, token_id)
  end

  defp replay_single_event(%PersistentData.ExternalTaskCancellation{} = event, acc) do
    task_id = event.external_task
    token_id = event.token
    state = acc.state

    acc = %{acc | open_external_tasks: Map.delete(acc.open_external_tasks, task_id)}

    state = if event.continuation_node_id do
      state = TokenState.update_token_node(state, token_id, event.continuation_node_id)
      TokenState.set_token_active(state, token_id)
    else
      TokenState.set_token_active(state, token_id)
    end

    acc = %{acc |
      state: state,
      token_wait_states: Map.delete(acc.token_wait_states, token_id)
    }
    track_token_id(acc, token_id)
  end

  defp replay_single_event(%PersistentData.TimerCreated{} = event, acc) do
    state = acc.state
    token_id = event.token
    timer_id = event.timer_id

    state = TokenState.update_token_node(state, token_id, event.current_node)
    state = TokenState.set_token_wait_state(state, token_id, :waiting_for_timer)
    state = TokenState.update_token_context(state, token_id, :intermediate_timer_id, timer_id)

    acc = %{acc |
      state: state,
      open_timers: Map.put(acc.open_timers, timer_id, %{
        token_id: token_id,
        trigger_at: event.trigger_at,
        target_node: event.target_node
      }),
      token_wait_states: Map.put(acc.token_wait_states, token_id, :waiting_for_timer)
    }
    track_token_id(acc, token_id)
  end

  defp replay_single_event(%PersistentData.TimerElapsed{} = event, acc) do
    state = acc.state
    token_id = event.token
    timer_id = event.timer_id

    acc = %{acc | open_timers: Map.delete(acc.open_timers, timer_id)}

    state = if event.target_node do
      TokenState.update_token_node(state, token_id, event.target_node)
    else
      state
    end

    state = TokenState.set_token_active(state, token_id)
    acc = %{acc |
      state: state,
      token_wait_states: Map.delete(acc.token_wait_states, token_id)
    }
    track_token_id(acc, token_id)
  end

  defp replay_single_event(%PersistentData.TimerCanceled{} = event, acc) do
    token_id = event.token
    timer_id = event.timer_id
    state = acc.state

    acc = %{acc | open_timers: Map.delete(acc.open_timers, timer_id)}

    state = TokenState.set_token_active(state, token_id)
    acc = %{acc |
      state: state,
      token_wait_states: Map.delete(acc.token_wait_states, token_id)
    }
    track_token_id(acc, token_id)
  end

  defp replay_single_event(%PersistentData.MessageWaitCreated{} = event, acc) do
    state = acc.state
    token_id = event.token
    name = event.name

    state = TokenState.update_token_node(state, token_id, event.current_node)
    state = TokenState.set_token_wait_state(state, token_id, :waiting_for_message)

    acc = %{acc |
      state: state,
      open_message_waits: Map.update(acc.open_message_waits, name, [token_id], &[token_id | &1]),
      token_wait_states: Map.put(acc.token_wait_states, token_id, :waiting_for_message)
    }

    track_token_id(acc, token_id)
  end

  defp replay_single_event(%PersistentData.SignalWaitCreated{} = event, acc) do
    state = acc.state
    token_id = event.token
    name = event.signal_name

    state = TokenState.update_token_node(state, token_id, event.current_node)
    state = TokenState.set_token_wait_state(state, token_id, :waiting_for_signal)

    acc = %{acc |
      state: state,
      open_signal_waits: Map.update(acc.open_signal_waits, name, [token_id], &[token_id | &1]),
      token_wait_states: Map.put(acc.token_wait_states, token_id, :waiting_for_signal)
    }

    track_token_id(acc, token_id)
  end

  defp replay_single_event(%PersistentData.BoundaryEventCreated{} = event, acc) do
    boundary_node = Chronicle.Engine.Diagrams.Definition.get_node(acc.state.definition, event.boundary_node_id)

    acc =
      case {event.boundary_type, event.interrupting, boundary_node} do
        {:message, true, boundary_node} when not is_nil(boundary_node) ->
          put_boundary(acc, :open_message_boundaries, event.name, event.token, boundary_node)

        {:message, false, boundary_node} when not is_nil(boundary_node) ->
          put_boundary(acc, :open_ni_message_boundaries, event.name, event.token, boundary_node)

        {:signal, true, boundary_node} when not is_nil(boundary_node) ->
          put_boundary(acc, :open_signal_boundaries, event.name, event.token, boundary_node)

        {:signal, false, boundary_node} when not is_nil(boundary_node) ->
          put_boundary(acc, :open_ni_signal_boundaries, event.name, event.token, boundary_node)

        {:timer, _interrupting, _} ->
          %{acc |
            open_timers: Map.put(acc.open_timers, event.timer_id || event.boundary_node_id, %{
              token_id: event.token,
              trigger_at: event.trigger_at,
              target_node: event.boundary_node_id,
              boundary_node_id: event.boundary_node_id,
              interrupting: event.interrupting
            })
          }

        _ ->
          acc
      end

    acc
    |> put_boundary_index(event)
    |> track_token_id(event.token)
  end

  defp replay_single_event(%PersistentData.BoundaryEventTriggered{} = event, acc) do
    state = TokenState.trigger_boundary(
      acc.state,
      event.token,
      event.boundary_node_id,
      event.interrupting != false
    )

    acc = %{acc | state: state}
    acc = delete_boundary_wait(acc, event)
    acc = %{acc | token_wait_states: Map.delete(acc.token_wait_states, event.token)}
    track_token_id(acc, event.token)
  end

  defp replay_single_event(%PersistentData.BoundaryEventCancelled{} = event, acc) do
    delete_boundary_wait(acc, event)
  end

  defp replay_single_event(%PersistentData.MessageThrown{} = event, acc) do
    state = acc.state
    state = TokenState.set_token_active(state, event.token)
    %{acc | state: state}
    |> track_token_id(event.token)
  end

  defp replay_single_event(%PersistentData.MessageHandled{} = event, acc) do
    state = acc.state
    token_id = event.token
    name = event.name

    acc = remove_from_open_waits(acc, :open_message_waits, name, token_id)

    state = if event.target_node do
      TokenState.update_token_node(state, token_id, event.target_node)
    else
      state
    end

    state = TokenState.set_token_active(state, token_id)
    acc = %{acc |
      state: state,
      token_wait_states: Map.delete(acc.token_wait_states, token_id)
    }
    track_token_id(acc, token_id)
  end

  defp replay_single_event(%PersistentData.SignalThrown{} = event, acc) do
    state = acc.state
    state = TokenState.set_token_active(state, event.token)
    %{acc | state: state}
    |> track_token_id(event.token)
  end

  defp replay_single_event(%PersistentData.SignalHandled{} = event, acc) do
    state = acc.state
    token_id = event.token
    name = event.signal_name

    acc = remove_from_open_waits(acc, :open_signal_waits, name, token_id)

    state = if event.target_node do
      TokenState.update_token_node(state, token_id, event.target_node)
    else
      state
    end

    state = TokenState.set_token_active(state, token_id)
    acc = %{acc |
      state: state,
      token_wait_states: Map.delete(acc.token_wait_states, token_id)
    }
    track_token_id(acc, token_id)
  end

  defp replay_single_event(%PersistentData.CallStarted{} = event, acc) do
    state = acc.state
    token_id = event.token
    child_id = event.started_process

    state = TokenState.update_token_node(state, token_id, event.current_node)
    state = TokenState.set_token_wait_state(state, token_id, :waiting_for_call)

    acc = %{acc |
      state: state,
      open_call_waits: Map.put(acc.open_call_waits, child_id, token_id),
      token_wait_states: Map.put(acc.token_wait_states, token_id, :waiting_for_call)
    }
    track_token_id(acc, token_id)
  end

  defp replay_single_event(%PersistentData.CallCompleted{} = event, acc) do
    replay_call_resolution(event, acc)
  end

  defp replay_single_event(%PersistentData.CallCanceled{} = event, acc) do
    replay_call_resolution(event, acc)
  end

  defp replay_single_event(%PersistentData.EscalationThrown{} = event, acc) do
    state = acc.state
    state = TokenState.set_token_active(state, event.token)
    %{acc | state: state}
    |> track_token_id(event.token)
  end

  defp replay_single_event(%PersistentData.ProcessInstanceMigrated{} = _event, acc) do
    acc
  end

  defp replay_single_event(unknown_event, acc) do
    Logger.warning("Instance #{acc.state.id}: Unknown event type during restoration: #{inspect(unknown_event.__struct__)}")
    acc
  end

  # --- Helpers ---

  defp replay_call_resolution(event, acc) do
    state = acc.state
    token_id = event.token

    child_id = Enum.find_value(acc.open_call_waits, fn
      {cid, ^token_id} -> cid
      _ -> nil
    end)

    acc = if child_id do
      %{acc | open_call_waits: Map.delete(acc.open_call_waits, child_id)}
    else
      acc
    end

    state = if event.next_node do
      TokenState.update_token_node(state, token_id, event.next_node)
    else
      state
    end

    state = TokenState.set_token_active(state, token_id)
    acc = %{acc |
      state: state,
      token_wait_states: Map.delete(acc.token_wait_states, token_id)
    }
    track_token_id(acc, token_id)
  end

  defp track_token_id(acc, token_id) do
    %{acc | max_token_id: max(acc.max_token_id, token_id)}
  end

  defp remove_from_open_waits(acc, wait_key, name, token_id) do
    waits = Map.get(acc, wait_key, %{})
    tokens_for_name = Map.get(waits, name, [])
    updated = List.delete(tokens_for_name, token_id)

    updated_waits = if updated == [] do
      Map.delete(waits, name)
    else
      Map.put(waits, name, updated)
    end

    Map.put(acc, wait_key, updated_waits)
  end

  defp put_boundary(acc, wait_key, name, token_id, boundary_node) do
    waits = Map.get(acc, wait_key, %{})
    waits = Map.update(waits, name, [{token_id, boundary_node}], &[{token_id, boundary_node} | &1])
    Map.put(acc, wait_key, waits)
  end

  defp put_boundary_index(acc, event) do
    info = %{
      type: event.boundary_type,
      boundary_node_id: event.boundary_node_id,
      timer_id: event.timer_id,
      name: event.name,
      interrupting: event.interrupting != false,
      trigger_at: event.trigger_at
    }

    state = update_in(acc.state.boundary_index[event.token], &[info | (&1 || [])])
    %{acc | state: state}
  end

  defp delete_boundary_wait(acc, %{boundary_type: :timer} = event) do
    %{acc | open_timers: Map.delete(acc.open_timers, event.timer_id || event.boundary_node_id)}
  end

  defp delete_boundary_wait(acc, %{boundary_type: :message} = event) do
    acc
    |> remove_from_open_boundaries(:open_message_boundaries, event.name, event.token)
    |> remove_from_open_boundaries(:open_ni_message_boundaries, event.name, event.token)
  end

  defp delete_boundary_wait(acc, %{boundary_type: :signal} = event) do
    acc
    |> remove_from_open_boundaries(:open_signal_boundaries, event.name, event.token)
    |> remove_from_open_boundaries(:open_ni_signal_boundaries, event.name, event.token)
  end

  defp delete_boundary_wait(acc, _event), do: acc

  defp remove_from_open_boundaries(acc, wait_key, name, token_id) do
    waits = Map.get(acc, wait_key, %{})
    boundaries = Map.get(waits, name, [])
    updated = Enum.reject(boundaries, fn {tid, _boundary} -> tid == token_id end)

    updated_waits = if updated == [] do
      Map.delete(waits, name)
    else
      Map.put(waits, name, updated)
    end

    Map.put(acc, wait_key, updated_waits)
  end

  defp detect_implicit_waits(state, token_wait_states, open_message_waits, open_signal_waits) do
    alias Chronicle.Engine.Nodes.IntermediateCatch
    alias Chronicle.Engine.Diagrams.Definition

    Enum.reduce(state.tokens, {state, token_wait_states, open_message_waits, open_signal_waits},
      fn {token_id, token}, {st, waits, msg_waits, sig_waits} ->
        if Map.has_key?(waits, token_id) or Token.terminal?(token) do
          {st, waits, msg_waits, sig_waits}
        else
          node = Definition.get_node(st.definition, token.current_node)
          case node do
            %IntermediateCatch.MessageEvent{} = msg_node ->
              name = resolve_message_name_for_restore(msg_node.message, token.parameters)
              st = TokenState.set_token_wait_state(st, token_id, :waiting_for_message)
              waits = Map.put(waits, token_id, :waiting_for_message)
              msg_waits = Map.update(msg_waits, name, [token_id], &[token_id | &1])
              {st, waits, msg_waits, sig_waits}

            %IntermediateCatch.SignalEvent{} = sig_node ->
              name = sig_node.signal
              st = TokenState.set_token_wait_state(st, token_id, :waiting_for_signal)
              waits = Map.put(waits, token_id, :waiting_for_signal)
              sig_waits = Map.update(sig_waits, name, [token_id], &[token_id | &1])
              {st, waits, msg_waits, sig_waits}

            _ ->
              {st, waits, msg_waits, sig_waits}
          end
        end
      end)
  end

  defp resolve_message_name_for_restore(%{static_text: text, variable_content: var}, params)
       when not is_nil(var) do
    variable_value = Map.get(params, var, "")
    "#{text}##{variable_value}"
  end
  defp resolve_message_name_for_restore(%{name: name}, _params), do: name
  defp resolve_message_name_for_restore(name, _params) when is_binary(name), do: name
  defp resolve_message_name_for_restore(_, _params), do: "unknown"

  defp reregister_timers(state, open_timers) do
    now_ms = System.system_time(:millisecond)

    Enum.reduce(open_timers, state, fn {_timer_id, timer_info}, acc ->
      token_id = timer_info.token_id
      trigger_at = timer_info.trigger_at

      remaining_ms = if trigger_at do
        max(trigger_at - now_ms, 0)
      else
        0
      end

      timer_ref = make_ref()
      msg =
        if timer_info[:boundary_node_id] do
          {:boundary_timer_elapsed, token_id, timer_info.boundary_node_id, timer_ref}
        else
          {:timer_elapsed, token_id, timer_ref}
        end

      ref = Process.send_after(self(), msg, remaining_ms)
      %{acc | timer_refs: Map.put(acc.timer_refs, ref, token_id)}
    end)
  end

  defp reregister_waits_in_registry(state, open_message_waits, open_signal_waits) do
    Enum.each(open_message_waits, fn {name, token_ids} ->
      Enum.each(token_ids, fn token_id ->
        Registry.register(:waits, {state.tenant_id, :message, name, state.business_key}, token_id)
      end)
    end)

    Enum.each(open_signal_waits, fn {name, token_ids} ->
      Enum.each(token_ids, fn token_id ->
        Registry.register(:waits, {state.tenant_id, :signal, name}, token_id)
      end)
    end)
  end

  defp reregister_boundaries_in_registry(state) do
    Enum.each([state.message_boundaries, state.ni_message_boundaries], fn waits ->
      Enum.each(waits || %{}, fn {name, boundaries} ->
        Enum.each(boundaries, fn {token_id, boundary} ->
          Registry.register(:waits, {state.tenant_id, :message, name, state.business_key}, {:boundary, token_id, boundary.id})
        end)
      end)
    end)

    Enum.each([state.signal_boundaries, state.ni_signal_boundaries], fn waits ->
      Enum.each(waits || %{}, fn {name, boundaries} ->
        Enum.each(boundaries, fn {token_id, boundary} ->
          Registry.register(:waits, {state.tenant_id, :signal, name}, {:boundary, token_id, boundary.id})
        end)
      end)
    end)
  end

  defp finalize_restored_state(state) do
    cond do
      MapSet.size(state.waiting_tokens) > 0 ->
        %{state | instance_state: :waiting, pin_state: :not_pinned, pin_reason: :none}

      MapSet.size(state.active_tokens) > 0 ->
        %{state | instance_state: :active, pin_state: :pinned, pin_reason: :active_token}

      true ->
        %{state | instance_state: :completed, pin_state: :not_pinned, pin_reason: :none}
    end
  end
end
