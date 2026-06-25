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

  @doc """
  Side-effect-free classifier: replay `events` against a freshly built base
  state and report whether the instance has any ACTIVE (in-flight, non-waiting,
  non-terminal) token.

  Used by the evicted-only boot-restore path
  (`Chronicle.Engine.EvictedWaitRestorer`) to decide whether an instance must be
  brought back RESIDENT-and-processed immediately (active token mid-processing,
  e.g. a WAKE event was recorded but the next wait/completion was never written)
  rather than parked as a passive evicted cell. Unlike `restore_from_events/2`
  this performs NO registry registration and arms NO timers — it only reuses the
  pure replay + token classification, so it is safe to call from any process.

  Returns `true` when at least one token classifies as active, `false` when the
  instance is purely waiting/completed, and `{:error, reason}` when the
  definition cannot be loaded (caller then falls back to the conservative
  evicted-cell path).
  """
  def has_active_tokens?(events, base_state) do
    case replay_open_state(events, base_state) do
      {:ok, {state, _open_timers}} ->
        {:ok, MapSet.size(state.active_tokens) > 0}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Side-effect-free FULL replay: rebuild the complete token/wait state — including
  the IMPLICIT message/signal waits `detect_implicit_waits/4` reconstructs for a
  token that durably reached a catch but crashed before its `MessageWaitCreated`
  was persisted — and return it together with the open-timer map.

  This is the authoritative source the evicted-boot restore
  (`Chronicle.Engine.EvictedWaitRestorer`) enumerates its open
  `WaitingHandle`s from, so the evicted path can NEVER diverge from the resident
  reconstruction: it reads the SAME `state.message_waits` / `signal_waits` /
  `external_tasks` / `call_wait_list` / boundary maps and the SAME open-timer map
  that `restore_from_events/2` builds, minus only the registry/timer side effects.

  Like `has_active_tokens?/2` this performs NO registry registration and arms NO
  timers, so it is safe to call from any process. Returns
  `{:ok, {state, open_timers}}` or `{:error, reason}` when the definition cannot
  be loaded (caller then falls back to its conservative path).
  """
  def replay_open_state(events, base_state) do
    start_event =
      Enum.find(events, fn
        %PersistentData.ProcessInstanceStart{} -> true
        _ -> false
      end)

    if start_event == nil do
      {:error, :no_start_event}
    else
      tenant_id = start_event.tenant || base_state.tenant_id

      case DiagramStore.get(start_event.process_name, start_event.process_version, tenant_id) do
        {:ok, definition} ->
          state = %{base_state |
            business_key: start_event.business_key,
            tenant_id: tenant_id,
            definition: definition,
            start_node_id: start_event.start_node_id
          }

          {state, open_timers, _msg_waits, _sig_waits} = replay_events_pure(events, state)
          {:ok, {state, open_timers}}

        _ ->
          {:error, :definition_unavailable}
      end
    end
  end

  @doc """
  Public wrapper over the resident `:no_key` opt-in test, so the evicted-boot
  restore decides a message wait's keyless flag with EXACTLY the resident
  semantics (`reregister_waits_in_registry` / `message_wait_keyless?/3`) instead
  of re-deriving it. Reads the catch node off `state.tokens[token_id]` — for an
  event-gateway branch the token sits on the gateway node, so the gateway
  candidate is consulted, mirroring the live registration.
  """
  def wait_keyless?(state, name, token_id) do
    message_wait_keyless?(state, name, token_id)
  end

  # Replays all events against the given state, returning the fully
  # reconstructed state with tokens, waits, and timers restored.
  defp replay_events(events, state) do
    {state, open_timers, open_message_waits, open_signal_waits} = replay_events_pure(events, state)

    # Re-register timers for tokens still waiting
    state = reregister_timers(state, open_timers)

    # Re-register message/signal waits in the Registry for cross-instance routing
    reregister_waits_in_registry(state, open_message_waits, open_signal_waits)
    reregister_boundaries_in_registry(state)

    state
  end

  # Pure core of the replay: rebuild token positions, waits and classify tokens
  # WITHOUT any side effect (no `Process.send_after`, no `Registry.register`).
  # `replay_events/2` layers the registry/timer re-registration on top; the
  # evicted-boot classifier (`has_active_tokens?/2`) uses this alone. Returns the
  # classified state plus the open-timer/message/signal maps the resident path
  # needs for re-registration.
  defp replay_events_pure(events, state) do
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
      # open_wait_ids: durable wait_id index rebuilt during replay, mirroring the
      # live state.wait_ids. Keyed by {:message, name, token_id} | {:gateway, token_id}
      # | {:boundary, token_id, boundary_id}. Used so a MessageHandled replay removes
      # the open wait by wait_id (NOT token_id) and can E4-close sibling gateway waits.
      open_wait_ids: %{},
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
      wait_ids: acc.open_wait_ids,
      next_token_id: acc.max_token_id + 1
    }

    # Detect message/signal waits from definition for tokens without explicit wait events
    {state, token_wait_states, open_message_waits, open_signal_waits} =
      detect_implicit_waits(state, acc.token_wait_states, acc.open_message_waits, acc.open_signal_waits)

    # Apply the final message/signal waits (including implicit ones) back to state
    state = %{state | message_waits: open_message_waits, signal_waits: open_signal_waits}

    # Classify tokens into active/waiting/completed sets
    state = TokenState.classify_tokens(state, token_wait_states)

    {state, acc.open_timers, open_message_waits, open_signal_waits}
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

    # External-task resolution: mirror the LIVE resume EXACTLY. The durable event
    # records "the task resolved" with current_node = the ExternalTask node
    # (instance.ex:842/883) and NO next_node (the post-wait move is produced by
    # continue_after_wait, not by this event). The token therefore stays on the
    # ExternalTask node and is set :continue so re-processing dispatches to
    # ExternalTask.continue_after_wait — NOT :execute_current_node, which would
    # re-run ExternalTask.process and RE-ARM a fresh external task (new UUID).
    #   * successful → {:complete, payload, result}  (wait_registry.ex:120)
    #   * failed     → {:error, error, retry?, backoff_ms} (wait_registry.ex:135)
    #     retry?/backoff are runtime-only (not persisted); reconstruct with
    #     retry? = false so continue_after_wait takes the deterministic
    #     fail/ignore branch (a :retry continuation cannot be re-derived from the
    #     durable log and was never advanced past the task before the crash).
    continuation =
      if event.successful do
        {:complete, event.payload, event.result}
      else
        {:error, event.error, false, nil}
      end

    state = TokenState.set_token_continue(state, token_id)
    state = TokenState.update_token_context(state, token_id, :continuation_context, continuation)

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

    # External-task cancellation: mirror the LIVE resume EXACTLY
    # (wait_registry.ex:151 `resume_token(token_id, {:cancel, reason, continuation_node_id})`).
    # The token stays on the ExternalTask node and is set :continue so re-processing
    # dispatches to ExternalTask.continue_after_wait, whose {:cancel, _, node} arm
    # returns NodeResult.next(continuation_node_id) — deterministically advancing to
    # the SAME node the live cancel routed to. Setting :execute_current_node on the
    # continuation node would instead re-run THAT node's process (and, worse, an
    # in-flight cancel raced detect_implicit_waits if the node were a catch).
    state = TokenState.set_token_continue(state, token_id)

    state =
      TokenState.update_token_context(
        state,
        token_id,
        :continuation_context,
        {:cancel, event.cancellation_reason, event.continuation_node_id}
      )

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
        timer_id: timer_id,
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

    # E4 twin (TIMER winner): a timer that WON an event-based gateway resolves
    # the gateway exactly like a message/signal winner. The live resume sets the
    # token :continue with the trigger `:timer_elapsed` (wait_registry.ex:235) and
    # closes every sibling branch wait. On crash-replay of ONLY TimerElapsed
    # (EventGatewayResolved not yet durable), the EventGatewayActivated replay
    # already re-opened every sibling message/signal wait — without this the token
    # would replay as :execute_current_node on the gateway node (re-arming every
    # branch) and stale sibling waits would remain. Detect the gateway-winner case
    # by the still-open gateway wait_id for this token (TimerElapsed carries no
    # selected_node), then mirror the MessageHandled gateway path EXACTLY.
    if event_gateway_winner?(acc, token_id) do
      resume_event_gateway_winner(acc, token_id, :timer_elapsed)
    else
      # Plain (non-gateway) intermediate timer resolution: mirror the LIVE resume
      # EXACTLY (wait_registry.ex:235 `resume_token(token_id, :timer_elapsed)`).
      # TimerElapsed.target_node is the TimerEvent catch node itself
      # (instance.ex:553 sets target_node: token.current_node), so the durable
      # event records "the timer fired", NOT a move onto the post-wait output.
      # The token therefore stays on the catch node and is set :continue so
      # re-processing dispatches to TimerEvent.continue_after_wait (advances to
      # the first output) — NOT :execute_current_node, which would re-run
      # TimerEvent.process and RE-ARM a fresh timer (a duplicate Process.send_after
      # via reregister_timers / a brand-new TimerCreated on the next cycle).
      # This is the timer twin of the MessageHandled plain clause.
      state = TokenState.set_token_continue(state, token_id)
      state = TokenState.update_token_context(state, token_id, :continuation_context, :timer_elapsed)

      acc = %{acc |
        state: state,
        token_wait_states: Map.delete(acc.token_wait_states, token_id)
      }
      track_token_id(acc, token_id)
    end
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
      open_wait_ids: put_wait_id(acc.open_wait_ids, {:message, name, token_id}, event.wait_id),
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

  defp replay_single_event(%PersistentData.EventGatewayActivated{} = event, acc) do
    state = acc.state
    token_id = event.token

    state = TokenState.update_token_node(state, token_id, event.current_node)
    state = TokenState.set_token_wait_state(state, token_id, :waiting_for_event_gateway)
    state = TokenState.update_token_context(state, token_id, :event_gateway_candidates, event_gateway_candidates_for(state, event.current_node))
    state = TokenState.update_token_context(state, token_id, :event_gateway_timer_ids, event.timer_ids || [])

    open_message_waits =
      Enum.reduce(event.message_names || [], acc.open_message_waits, fn name, waits ->
        Map.update(waits, name, [token_id], &[token_id | &1])
      end)

    open_signal_waits =
      Enum.reduce(event.signal_names || [], acc.open_signal_waits, fn name, waits ->
        Map.update(waits, name, [token_id], &[token_id | &1])
      end)

    acc = %{acc |
      state: state,
      open_message_waits: open_message_waits,
      open_signal_waits: open_signal_waits,
      open_wait_ids: put_wait_id(acc.open_wait_ids, {:gateway, token_id}, event.wait_id),
      token_wait_states: Map.put(acc.token_wait_states, token_id, :waiting_for_event_gateway)
    }

    track_token_id(acc, token_id)
  end

  defp replay_single_event(%PersistentData.EventGatewayResolved{} = event, acc) do
    state = acc.state
    token_id = event.token

    state =
      if event.target_node do
        TokenState.update_token_node(state, token_id, event.target_node)
      else
        state
      end

    state = TokenState.set_token_active(state, token_id)

    acc = %{acc |
      state: state,
      open_message_waits: remove_token_from_all_waits(acc.open_message_waits, token_id),
      open_signal_waits: remove_token_from_all_waits(acc.open_signal_waits, token_id),
      open_wait_ids: forget_token_wait_ids(acc.open_wait_ids, token_id),
      token_wait_states: Map.delete(acc.token_wait_states, token_id)
    }

    track_token_id(acc, token_id)
  end

  defp replay_single_event(%PersistentData.ConditionalEventWaitCreated{} = event, acc) do
    state = acc.state
    token_id = event.token

    state = TokenState.update_token_node(state, token_id, event.current_node)
    state = TokenState.set_token_wait_state(state, token_id, :waiting_for_conditional_event)

    acc = %{acc |
      state: state,
      token_wait_states: Map.put(acc.token_wait_states, token_id, :waiting_for_conditional_event)
    }

    track_token_id(acc, token_id)
  end

  defp replay_single_event(%PersistentData.ConditionalEventEvaluated{matched: true} = event, acc) do
    state = acc.state
    token_id = event.token

    state =
      if event.target_node do
        TokenState.update_token_node(state, token_id, event.target_node)
      else
        state
      end

    state = TokenState.set_token_active(state, token_id)
    acc = %{acc | state: state, token_wait_states: Map.delete(acc.token_wait_states, token_id)}
    track_token_id(acc, token_id)
  end

  defp replay_single_event(%PersistentData.ConditionalEventEvaluated{} = event, acc) do
    track_token_id(acc, event.token)
  end

  defp replay_single_event(%PersistentData.LoopConditionEvaluated{} = event, acc) do
    state =
      acc.state
      |> TokenState.update_token_node(event.token, event.target_node || event.current_node)
      |> TokenState.update_token_context(event.token, :loop_iterations, %{event.current_node => event.iteration})
      |> TokenState.set_token_active(event.token)

    %{acc | state: state, token_wait_states: Map.delete(acc.token_wait_states, event.token)}
    |> track_token_id(event.token)
  end

  defp replay_single_event(%PersistentData.VariablesUpdated{} = event, acc) do
    state =
      case Map.get(acc.state.tokens, event.token) do
        nil ->
          acc.state

        token ->
          token = %{token | parameters: Map.merge(token.parameters || %{}, event.variables || %{})}
          %{acc.state | tokens: Map.put(acc.state.tokens, event.token, token)}
      end

    %{acc | state: state}
    |> track_token_id(event.token)
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
              timer_id: event.timer_id || event.boundary_node_id,
              trigger_at: event.trigger_at,
              target_node: event.boundary_node_id,
              boundary_node_id: event.boundary_node_id,
              interrupting: event.interrupting
            })
          }

        {:conditional, _interrupting, _} ->
          acc

        _ ->
          acc
      end

    # Record the durable wait_id for a message boundary occurrence so a
    # BoundaryEventTriggered replay (and the live trigger_event lookup after restore)
    # can resolve it.
    acc =
      if event.boundary_type == :message and not is_nil(event.wait_id) do
        %{acc |
          open_wait_ids:
            put_wait_id(acc.open_wait_ids, {:boundary, event.token, event.boundary_node_id}, event.wait_id)}
      else
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

    acc =
      cond do
        event.interrupting != false ->
          acc
          |> delete_boundary_wait(event)
          |> delete_token_wait_handles(event.token)
          |> Map.put(:open_wait_ids, Map.delete(acc.open_wait_ids, {:boundary, event.token, event.boundary_node_id}))
          |> Map.put(:token_wait_states, Map.delete(acc.token_wait_states, event.token))

        event.boundary_type == :timer ->
          # Non-interrupting timer boundaries are one-shot: triggering creates
          # a sibling boundary token and closes this timer registration while
          # the original activity wait remains open.
          delete_boundary_wait(acc, event)

        true ->
          # Non-interrupting message/signal boundaries remain registered and
          # can trigger again while the activity is still waiting.
          acc
      end

    max_token_id =
      acc.state.tokens
      |> Map.keys()
      |> Enum.reduce(event.token, &max/2)

    %{acc | max_token_id: max(acc.max_token_id, max_token_id)}
  end

  defp replay_single_event(%PersistentData.BoundaryEventCancelled{} = event, acc) do
    delete_boundary_wait(acc, event)
  end

  defp replay_single_event(%PersistentData.CompensationHandlerRegistered{}, acc), do: acc

  defp replay_single_event(%PersistentData.CompensatableActivityCompleted{} = event, acc) do
    activity = %{
      token: event.token,
      family: event.family,
      activity_node_id: event.activity_node_id,
      handler_node_id: event.handler_node_id,
      activity_instance_key: event.activity_instance_key
    }

    state = Map.update!(acc.state, :compensatable_activities, &Map.put(&1, event.activity_instance_key, activity))
    %{acc | state: state}
    |> track_token_id(event.token)
  end

  defp replay_single_event(%PersistentData.CompensationRequested{} = event, acc) do
    track_token_id(acc, event.token)
  end

  defp replay_single_event(%PersistentData.CompensationHandlerStarted{} = event, acc) do
    state = acc.state
    handler_token = Token.new(event.handler_token, event.family, event.handler_node_id, %{})
    handler_token =
      handler_token
      |> Token.set_context(:compensation_activity_key, event.activity_instance_key)
      |> Token.set_context(:compensation_handler_node_id, event.handler_node_id)

    state = %{state |
      tokens: Map.put(state.tokens, event.handler_token, handler_token),
      compensation_started: MapSet.put(state.compensation_started || MapSet.new(), event.activity_instance_key)
    }

    %{acc | state: state}
    |> track_token_id(event.handler_token)
  end

  defp replay_single_event(%PersistentData.CompensationHandlerCompleted{} = event, acc) do
    state =
      acc.state
      |> TokenState.update_token_node(event.token, event.current_node)

    token = Map.get(state.tokens, event.token)
    state =
      if token do
        %{state | tokens: Map.put(state.tokens, event.token, Token.complete(token))}
      else
        state
      end

    %{acc | state: state}
    |> track_token_id(event.token)
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

    # E4 durability: if this delivery selected an event-gateway branch
    # (selected_node present, or the open wait for this token is a gateway wait),
    # close ALL of that gateway's sibling message/signal waits — not just `name`.
    # On crash-replay of only MessageHandled (EventGatewayResolved not yet durable),
    # the EventGatewayActivated replay already re-opened every sibling branch wait;
    # without this, a sibling could double-fire post-replay. Remove the consumed wait
    # by wait_id identity (NOT token_id) so a loop-back to the same catch is unaffected.
    gateway_wait? =
      not is_nil(event.selected_node) or
        not is_nil(Map.get(acc.open_wait_ids, {:gateway, token_id}))

    acc =
      if gateway_wait? do
        %{acc |
          open_message_waits: remove_token_from_all_waits(acc.open_message_waits, token_id),
          open_signal_waits: remove_token_from_all_waits(acc.open_signal_waits, token_id),
          open_wait_ids: forget_token_wait_ids(acc.open_wait_ids, token_id)
        }
      else
        # Remove the consumed wait BY wait_id (B'.1 / item 2): drop only the open
        # occurrence whose persisted wait_id matches event.wait_id, so a loop-back to
        # the same catch (same token_id + name, DIFFERENT wait_id) is not closed by a
        # prior occurrence's MessageHandled. Fall back to the occurrence-tuple key only
        # when the event predates wait_id.
        acc
        |> remove_from_open_waits(:open_message_waits, name, token_id)
        |> Map.put(:open_wait_ids, forget_wait_occurrence(acc.open_wait_ids, event.wait_id, {:message, name, token_id}))
      end

    state = if event.target_node do
      TokenState.update_token_node(state, token_id, event.target_node)
    else
      state
    end

    # E4 CONTINUATION durability: for a gateway delivery, MessageHandled.target_node is the
    # GATEWAY node itself (instance.ex sets target_node: token.current_node), and the durable
    # EventGatewayResolved that actually moves the token onto the selected branch is appended
    # in a LATER token-processing cycle. On crash-replay of ONLY MessageHandled, the token must
    # NOT be replayed as :execute_current_node on the gateway node — that would route to
    # Gateway.process/process_event_based and RE-OPEN every branch wait (re-arming the gateway).
    # Instead mirror the LIVE resume: put the token into :continue with the reconstructed resume
    # trigger {:message, name, payload, selected_node} (the same 4-tuple WaitRegistry resumes
    # with live — wait_registry.ex:55 / gateway.ex:182). do_update_token then dispatches to
    # Gateway.continue_after_wait → continue_event_based, which selects the SELECTED branch
    # (gateway.ex:182) and durably re-appends EventGatewayResolved, moving the token to the
    # branch continuation. Sibling waits were already closed above, so exactly ONE branch is
    # active and it durably continues. Plain (non-gateway) deliveries keep the existing
    # :execute_current_node behaviour on the post-catch target_node.
    state =
      if gateway_wait? and not is_nil(event.selected_node) do
        state = TokenState.set_token_continue(state, token_id)

        TokenState.update_token_context(
          state,
          token_id,
          :continuation_context,
          {:message, name, event.payload, event.selected_node}
        )
      else
        # Plain (non-gateway) catch consumption: mirror the LIVE resume exactly
        # (token.ex `continue/1`) — set the token to :continue so post-replay it is
        # dispatched to the catch node's `continue_after_wait` (which advances to the
        # outputs), NOT to `process` (which would re-arm a fresh wait). Setting it
        # :execute_current_node here re-ran the catch and, with the token still parked
        # on the MessageEvent node, made `detect_implicit_waits` re-open the wait that
        # this MessageHandled just consumed — leaving message_waits[name] == [token]
        # for a wait that was legitimately removed by wait_id.
        TokenState.set_token_continue(state, token_id)
      end

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

    # E4 twin (SIGNAL winner): a signal that WON an event-based gateway resolves
    # the gateway exactly like a message winner. The live resume sets the token
    # :continue with the trigger `{:signal, name}` (wait_registry.ex:94) and closes
    # every sibling branch wait. On crash-replay of ONLY SignalHandled
    # (EventGatewayResolved not yet durable), the EventGatewayActivated replay
    # already re-opened every sibling message/signal wait — without this the token
    # would replay as :execute_current_node on the gateway node (re-arming every
    # branch) and stale sibling waits would remain. Detect the gateway-winner case
    # by the still-open gateway wait_id for this token (SignalHandled carries no
    # selected_node), then mirror the MessageHandled gateway path EXACTLY.
    if event_gateway_winner?(acc, token_id) do
      resume_event_gateway_winner(acc, token_id, {:signal, name})
    else
      # Plain (non-gateway) signal catch resolution: mirror the LIVE resume
      # EXACTLY (wait_registry.ex:94 `resume_token(token_id, {:signal, name})`).
      # SignalHandled.target_node is the SignalEvent catch node itself
      # (instance.ex:1195 sets target_node: token.current_node), so the durable
      # event records "the signal was consumed", NOT a move onto the post-wait
      # output. The token therefore stays on the catch node and is set :continue
      # so re-processing dispatches to SignalEvent.continue_after_wait (advances
      # to the first output) — NOT :execute_current_node, which would re-run
      # SignalEvent.process and re-arm a fresh wait_for_signal. Leaving it
      # :execute_current_node also let detect_implicit_waits resurrect the very
      # signal wait this event consumed (token parked on a SignalEvent node, not
      # in :continue). This is the signal twin of the MessageHandled plain clause.
      acc = remove_from_open_waits(acc, :open_signal_waits, name, token_id)

      state = TokenState.set_token_continue(state, token_id)
      state = TokenState.update_token_context(state, token_id, :continuation_context, {:signal, name})

      acc = %{acc |
        state: state,
        token_wait_states: Map.delete(acc.token_wait_states, token_id)
      }
      track_token_id(acc, token_id)
    end
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
    replay_call_resolution(event, acc, {:completed, event.completion_context, event.successful})
  end

  defp replay_single_event(%PersistentData.CallCanceled{} = event, acc) do
    replay_call_resolution(event, acc, {:canceled, event.next_node})
  end

  defp replay_single_event(%PersistentData.EscalationThrown{} = event, acc) do
    state = acc.state
    state = TokenState.set_token_active(state, event.token)
    %{acc | state: state}
    |> track_token_id(event.token)
  end

  defp replay_single_event(%PersistentData.LinkTraversed{} = event, acc) do
    state =
      acc.state
      |> TokenState.update_token_node(event.token, event.target_node)
      |> TokenState.set_token_active(event.token)

    %{acc | state: state}
    |> track_token_id(event.token)
  end

  defp replay_single_event(%PersistentData.NoOpTaskCompleted{} = event, acc) do
    state =
      acc.state
      |> TokenState.update_token_node(event.token, event.target_node)
      |> TokenState.set_token_active(event.token)

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

  defp delete_token_wait_handles(acc, token_id) do
    %{
      acc
      | open_external_tasks: reject_waits_for_token(acc.open_external_tasks, token_id),
        open_call_waits: reject_waits_for_token(acc.open_call_waits, token_id)
    }
  end

  defp reject_waits_for_token(waits, token_id) do
    waits
    |> Enum.reject(fn {_wait_id, owner_token_id} -> owner_token_id == token_id end)
    |> Map.new()
  end

  defp replay_call_resolution(event, acc, continuation) do
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

    # Call-activity resolution (completion or cancellation): mirror the LIVE resume
    # EXACTLY. CallCompleted is persisted with current_node = the CallActivity node
    # and NO next_node (instance.ex:395 — the post-wait move is produced by
    # continue_after_wait, not by this event). The token therefore stays on the
    # CallActivity node and is set :continue so re-processing dispatches to
    # CallActivity.continue_after_wait — NOT :execute_current_node, which would
    # re-run CallActivity.process and START A SECOND CHILD process instance.
    #   * CallCompleted → {:completed, completion_context, successful} (wait_registry.ex:184)
    #     continue_after_wait advances to the first output (or steps a sequential loop).
    #   * CallCanceled  → {:canceled, next_node} (wait_registry.ex:201)
    #     continue_after_wait returns NodeResult.next(next_node).
    state = TokenState.set_token_continue(state, token_id)
    state = TokenState.update_token_context(state, token_id, :continuation_context, continuation)

    acc = %{acc |
      state: state,
      token_wait_states: Map.delete(acc.token_wait_states, token_id)
    }
    track_token_id(acc, token_id)
  end

  defp track_token_id(acc, token_id) do
    %{acc | max_token_id: max(acc.max_token_id, token_id)}
  end

  # E4 twin: true iff the token is parked on an event-based gateway whose durable
  # wait occurrence is still OPEN (the gateway has NOT been resolved yet). This is
  # the gateway-winner signal/timer counterpart of the MessageHandled gateway test
  # — but SignalHandled/TimerElapsed carry no `selected_node`, so the ONLY signal is
  # the still-open `{:gateway, token_id}` wait_id minted by EventGatewayActivated
  # replay and removed by EventGatewayResolved replay. When EventGatewayResolved IS
  # present (no-crash path), it ran first and cleared this entry, so this is false
  # and the plain (re-arm-free) signal/timer handling applies unchanged.
  defp event_gateway_winner?(acc, token_id) do
    not is_nil(Map.get(acc.open_wait_ids, {:gateway, token_id}))
  end

  # E4 twin: resolve an event-based gateway won by a SIGNAL or TIMER on crash-replay
  # of only SignalHandled / TimerElapsed (EventGatewayResolved not yet durable).
  # Mirrors the MessageHandled gateway clause EXACTLY (event_replayer.ex MessageHandled):
  #   * close ALL of this gateway's sibling message/signal candidate waits (re-opened
  #     by EventGatewayActivated replay) and forget the gateway's wait_id index entry,
  #     so exactly ONE branch survives and no sibling can double-fire;
  #   * leave the token on the GATEWAY node and set it :continue with the reconstructed
  #     resume trigger (`{:signal, name}` / `:timer_elapsed`, the SAME tuple the live
  #     WaitRegistry resumes with — wait_registry.ex:94 / :235), so re-processing
  #     dispatches to Gateway.continue_after_wait → continue_event_based, which selects
  #     the SELECTED branch and durably re-appends EventGatewayResolved.
  # Holds for both resident restore and the evicted path (both derive waits from this
  # same replay state).
  defp resume_event_gateway_winner(acc, token_id, continuation_trigger) do
    acc = %{acc |
      open_message_waits: remove_token_from_all_waits(acc.open_message_waits, token_id),
      open_signal_waits: remove_token_from_all_waits(acc.open_signal_waits, token_id),
      open_wait_ids: forget_token_wait_ids(acc.open_wait_ids, token_id)
    }

    state = TokenState.set_token_continue(acc.state, token_id)
    state = TokenState.update_token_context(state, token_id, :continuation_context, continuation_trigger)

    acc = %{acc |
      state: state,
      token_wait_states: Map.delete(acc.token_wait_states, token_id)
    }
    track_token_id(acc, token_id)
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

  defp remove_token_from_all_waits(waits, token_id) do
    Enum.reduce(waits || %{}, %{}, fn {name, token_ids}, acc ->
      remaining = List.delete(token_ids, token_id)
      if remaining == [], do: acc, else: Map.put(acc, name, remaining)
    end)
  end

  # Records a durable wait_id in the open index. A nil wait_id (events persisted by
  # pre-wait_id code, if any) is ignored so the index stays clean.
  defp put_wait_id(wait_ids, _key, nil), do: wait_ids
  defp put_wait_id(wait_ids, key, wait_id), do: Map.put(wait_ids, key, wait_id)

  # Drops the open wait_id index entry consumed by a delivery. Prefers removal BY
  # wait_id value (so a loop-back occurrence reusing the same token_id/name but a
  # different wait_id is preserved); falls back to the occurrence-tuple key when the
  # event carries no wait_id (pre-wait_id events).
  defp forget_wait_occurrence(wait_ids, nil, fallback_key), do: Map.delete(wait_ids, fallback_key)

  defp forget_wait_occurrence(wait_ids, wait_id, fallback_key) do
    removed = :maps.filter(fn _k, v -> v != wait_id end, wait_ids)

    if map_size(removed) == map_size(wait_ids) do
      # No entry carried this wait_id (e.g. mixed pre-wait_id data) — use the key.
      Map.delete(wait_ids, fallback_key)
    else
      removed
    end
  end

  # Drops every wait_id index entry owned by a token (gateway resolution / message
  # consumption that closes all of a token's waits).
  defp forget_token_wait_ids(wait_ids, token_id) do
    wait_ids
    |> Enum.reject(fn
      {{:message, _name, tid}, _} -> tid == token_id
      {{:gateway, tid}, _} -> tid == token_id
      {{:boundary, tid, _bid}, _} -> tid == token_id
      _ -> false
    end)
    |> Map.new()
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
      condition: Map.get(event, :condition),
      interrupting: event.interrupting != false,
      trigger_at: event.trigger_at
    }

    boundary_index =
      Map.update(acc.state.boundary_index || %{}, event.token, [info], &[info | (&1 || [])])

    state = %{acc.state | boundary_index: boundary_index}
    %{acc | state: state}
  end

  defp delete_boundary_wait(acc, %{boundary_type: :timer} = event) do
    acc
    |> Map.put(:open_timers, Map.delete(acc.open_timers, event.timer_id || event.boundary_node_id))
    |> delete_boundary_index(event)
  end

  defp delete_boundary_wait(acc, %{boundary_type: :message} = event) do
    acc
    |> remove_from_open_boundaries(:open_message_boundaries, event.name, event.token)
    |> remove_from_open_boundaries(:open_ni_message_boundaries, event.name, event.token)
    |> delete_boundary_index(event)
  end

  defp delete_boundary_wait(acc, %{boundary_type: :signal} = event) do
    acc
    |> remove_from_open_boundaries(:open_signal_boundaries, event.name, event.token)
    |> remove_from_open_boundaries(:open_ni_signal_boundaries, event.name, event.token)
    |> delete_boundary_index(event)
  end

  defp delete_boundary_wait(acc, %{boundary_type: :conditional} = event) do
    delete_boundary_index(acc, event)
  end

  defp delete_boundary_wait(acc, event), do: delete_boundary_index(acc, event)

  defp delete_boundary_index(acc, %{token: token_id, boundary_node_id: boundary_node_id}) do
    boundary_index =
      acc.state.boundary_index
      |> Map.update(token_id, [], fn infos ->
        (infos || [])
        |> Enum.reject(&(&1.boundary_node_id == boundary_node_id))
      end)

    boundary_index =
      if Map.get(boundary_index, token_id) in [nil, []] do
        Map.delete(boundary_index, token_id)
      else
        boundary_index
      end

    state = %{acc.state | boundary_index: boundary_index}

    %{acc | state: state}
  end

  defp delete_boundary_index(acc, _event), do: acc

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
        # Skip tokens that are not genuinely parked at an un-registered catch:
        #   * already tracked as waiting (explicit wait event), or terminal; and
        #   * in the :continue resume state — a MessageHandled just consumed this
        #     token's wait and it is mid-advance through `continue_after_wait`, so it
        #     must NOT be re-armed (that would resurrect the consumed wait). The
        #     legitimate implicit case (crash before MessageWaitCreated persisted)
        #     leaves the token in :execute_current_node, which is still detected.
        if Map.has_key?(waits, token_id) or Token.terminal?(token) or token.state == :continue do
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

  defp event_gateway_candidates_for(state, gateway_node_id) do
    gateway = Chronicle.Engine.Diagrams.Definition.get_node(state.definition, gateway_node_id)
    params =
      state.tokens
      |> Map.values()
      |> Enum.find_value(%{}, fn
        %{current_node: ^gateway_node_id, parameters: parameters} -> parameters
        _ -> nil
      end)

    (Map.get(gateway || %{}, :outputs, []) || [])
    |> Enum.map(&Chronicle.Engine.Diagrams.Definition.get_node(state.definition, &1))
    |> Enum.map(fn
      %Chronicle.Engine.Nodes.IntermediateCatch.MessageEvent{} = node ->
        %{type: :message, name: resolve_message_name_for_restore(node.message, params), node_id: node.id}

      %Chronicle.Engine.Nodes.Tasks.ReceiveTask{} = node ->
        %{type: :message, name: resolve_message_name_for_restore(node.message, params), node_id: node.id}

      %Chronicle.Engine.Nodes.IntermediateCatch.SignalEvent{} = node ->
        %{type: :signal, name: node.signal, node_id: node.id}

      %Chronicle.Engine.Nodes.IntermediateCatch.TimerEvent{} = node ->
        %{type: :timer, node_id: node.id, timer_config: node.timer_config}

      _ ->
        nil
    end)
    |> Enum.reject(&is_nil/1)
  end

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

      msg =
        if timer_info[:boundary_node_id] do
          {:boundary_timer_elapsed, token_id, timer_info.boundary_node_id, timer_info[:timer_id]}
        else
          {:timer_elapsed, token_id, timer_info[:timer_id]}
        end

      ref = Process.send_after(self(), msg, remaining_ms)
      %{acc |
        timer_refs: Map.put(acc.timer_refs, ref, token_id),
        timer_ref_ids: Map.put(acc.timer_ref_ids || %{}, ref, timer_info[:timer_id])
      }
    end)
  end

  defp reregister_waits_in_registry(state, open_message_waits, open_signal_waits) do
    wait_ids = state.wait_ids || %{}

    Enum.each(open_message_waits, fn {name, token_ids} ->
      Enum.each(token_ids, fn token_id ->
        # Re-register with the PERSISTED wait_id as the value identity (B'.1), so a
        # restored instance carries the same wait_id the gateway/retention store keyed
        # on before the restart — NOT a fresh id and NOT the bare token_id. A gateway
        # candidate's wait_id is stored under {:gateway, token_id}; a plain message wait
        # under {:message, name, token_id}.
        wait_id =
          Map.get(wait_ids, {:message, name, token_id}) ||
            Map.get(wait_ids, {:gateway, token_id})

        Registry.register(:waits, {state.tenant_id, :message, name, state.business_key}, {token_id, wait_id})

        if message_wait_keyless?(state, name, token_id) do
          Registry.register(:waits, {state.tenant_id, :message, name, :no_key}, {token_id, wait_id})
        end
      end)
    end)

    Enum.each(open_signal_waits, fn {name, token_ids} ->
      Enum.each(token_ids, fn token_id ->
        Registry.register(:waits, {state.tenant_id, :signal, name}, token_id)
      end)
    end)
  end

  defp reregister_boundaries_in_registry(state) do
    wait_ids = state.wait_ids || %{}

    Enum.each([state.message_boundaries, state.ni_message_boundaries], fn waits ->
      Enum.each(waits || %{}, fn {name, boundaries} ->
        Enum.each(boundaries, fn {token_id, boundary} ->
          boundary_wait_id = Map.get(wait_ids, {:boundary, token_id, boundary.id})
          Registry.register(:waits, {state.tenant_id, :message, name, state.business_key}, {:boundary, token_id, boundary.id, boundary_wait_id})

          if boundary_node_keyless?(state, boundary) do
            Registry.register(:waits, {state.tenant_id, :message, name, :no_key}, {:boundary, token_id, boundary.id, boundary_wait_id})
          end
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

  # B'.5 keyless re-registration on restore. Mirrors token_processor: a wait whose
  # catch node carries the explicit keyless annotation also re-registers under :no_key.
  #
  # For an EVENT-GATEWAY message branch the token sits on the GATEWAY node (NOT the
  # branch catch node), so reading token.current_node would miss the annotation and the
  # keyless route would NOT be restored — the nested-catch C1 restore gap. Mirror the
  # live registration (token_processor candidate_keyless?): when the wait belongs to a
  # gateway, test the matching message CANDIDATE branch node for this `name`.
  defp message_wait_keyless?(state, name, token_id) do
    case Map.get(state.tokens, token_id) do
      nil ->
        false

      token ->
        node = Chronicle.Engine.Diagrams.Definition.get_node(state.definition, token.current_node)

        case node do
          %Chronicle.Engine.Nodes.Gateway{kind: :event_based} ->
            gateway_candidate_keyless?(state, token, name)

          _ ->
            node_message_keyless?(node)
        end
    end
  end

  # A gateway message branch is keyless iff its candidate branch node (the catch the
  # candidate points at) carries the explicit annotation. Matches the live site at
  # token_processor.ex candidate_keyless?/2.
  defp gateway_candidate_keyless?(state, token, name) do
    (token.context[:event_gateway_candidates] || [])
    |> List.wrap()
    |> Enum.filter(&(&1[:type] == :message and &1[:name] == name))
    |> Enum.any?(fn candidate ->
      state.definition
      |> Chronicle.Engine.Diagrams.Definition.get_node(candidate[:node_id])
      |> node_message_keyless?()
    end)
  end

  # The boundary value is the parsed boundary struct already carrying its message map.
  defp boundary_node_keyless?(_state, boundary) do
    match?(%{allow_keyless: true}, Map.get(boundary, :message) || %{})
  end

  defp node_message_keyless?(nil), do: false
  defp node_message_keyless?(node), do: match?(%{allow_keyless: true}, Map.get(node, :message) || %{})

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
