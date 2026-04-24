defmodule Chronicle.Engine.Instance.TokenState do
  @moduledoc """
  Pure functions for manipulating token state within a process instance.
  Handles token creation, node updates, wait-state transitions, and
  classification of tokens into active/waiting/completed sets.
  """

  require Logger

  alias Chronicle.Engine.Token

  @doc """
  Returns the base state map with all fields initialized to defaults.
  Callers merge in their specific overrides.
  """
  def base_state do
    %{
      id: nil,
      business_key: nil,
      tenant_id: nil,
      definition: nil,
      instance_state: :active,
      tokens: %{},
      active_tokens: MapSet.new(),
      waiting_tokens: MapSet.new(),
      completed_tokens: MapSet.new(),
      token_families: MapSet.new(),
      joining_list: %{},
      message_waits: %{},
      signal_waits: %{},
      message_boundaries: %{},
      signal_boundaries: %{},
      ni_message_boundaries: %{},
      ni_signal_boundaries: %{},
      boundary_index: %{},
      compensatable_activities: %{},
      compensation_started: MapSet.new(),
      call_wait_list: %{},
      external_tasks: %{},
      script_waits: %{},
      parent_id: nil,
      parent_business_key: nil,
      root_id: nil,
      root_business_key: nil,
      pin_state: :pinned,
      pin_reason: :active_token,
      next_token_id: 0,
      timer_refs: %{},
      timer_ref_ids: %{},
      pending_effects: [],
      persistent_events: [],
      last_persisted_index: 0,
      start_parameters: %{},
      start_node_id: nil
    }
  end

  @doc """
  Creates a new token with the given family, node, and parameters.
  Returns {token, updated_state}.
  """
  def create_token(state, family, node_id, params) do
    token_id = state.next_token_id
    token = Token.new(token_id, family, node_id, params)
    state = %{state |
      tokens: Map.put(state.tokens, token_id, token),
      next_token_id: token_id + 1
    }
    {token, state}
  end

  @doc """
  Updates a token's current_node. Creates a placeholder token if not found.
  """
  def update_token_node(state, token_id, node_id) do
    case Map.get(state.tokens, token_id) do
      nil ->
        Logger.warning("Instance #{state.id}: Token #{token_id} not found during restoration, creating placeholder")
        token = Token.new(token_id, 0, node_id)
        %{state | tokens: Map.put(state.tokens, token_id, token)}

      token ->
        token = %{token | current_node: node_id}
        %{state | tokens: Map.put(state.tokens, token_id, token)}
    end
  end

  @doc """
  Updates a specific key in a token's context.
  """
  def update_token_context(state, token_id, key, value) do
    case Map.get(state.tokens, token_id) do
      nil -> state
      token ->
        token = Token.set_context(token, key, value)
        %{state | tokens: Map.put(state.tokens, token_id, token)}
    end
  end

  @doc """
  Sets a token into a specific wait state (e.g. :waiting_for_external_task).
  """
  def set_token_wait_state(state, token_id, wait_type) do
    case Map.get(state.tokens, token_id) do
      nil -> state
      token ->
        token = Token.set_waiting(token, wait_type)
        %{state | tokens: Map.put(state.tokens, token_id, token)}
    end
  end

  @doc """
  Sets a token back to active (:execute_current_node) state.
  """
  def set_token_active(state, token_id) do
    case Map.get(state.tokens, token_id) do
      nil -> state
      token ->
        token = %{token | state: :execute_current_node}
        %{state | tokens: Map.put(state.tokens, token_id, token)}
    end
  end

  @doc """
  Resumes a waiting token with continuation data, moving it from
  waiting_tokens to active_tokens and pinning the instance.
  """
  def resume_token(state, token_id, continuation_data) do
    case Map.get(state.tokens, token_id) do
      nil -> state
      token ->
        token = token
          |> Token.continue()
          |> Token.set_context(:continuation_context, continuation_data)
        state = %{state |
          tokens: Map.put(state.tokens, token_id, token),
          waiting_tokens: MapSet.delete(state.waiting_tokens, token_id),
          active_tokens: MapSet.put(state.active_tokens, token_id)
        }
        %{state | pin_state: :pinned, pin_reason: :active_token}
    end
  end

  @doc """
  Interrupts a token and redirects it to a boundary node path.
  """
  def interrupt_token(state, token_id, boundary_node_id) do
    case Map.get(state.tokens, token_id) do
      nil -> state
      token ->
        token = Token.interrupt(token)
        token = %{token | current_node: boundary_node_id, state: :execute_current_node}
        %{state |
          tokens: Map.put(state.tokens, token_id, token),
          waiting_tokens: MapSet.delete(state.waiting_tokens, token_id),
          active_tokens: MapSet.put(state.active_tokens, token_id),
          pin_state: :pinned,
          pin_reason: :active_token
        }
    end
  end

  @doc """
  Triggers a boundary event.

  Interrupting boundaries redirect the waiting token to the boundary node.
  Non-interrupting boundaries leave the original token untouched and create a
  sibling token that starts at the boundary node.
  """
  def trigger_boundary(state, token_id, boundary_node_id, interrupting?) do
    case {Map.get(state.tokens, token_id), interrupting?} do
      {nil, _} ->
        state

      {_token, true} ->
        interrupt_token(state, token_id, boundary_node_id)

      {token, false} ->
        new_token_id = state.next_token_id
        new_token = Token.new(new_token_id, token.family, boundary_node_id, token.parameters)

        %{state |
          tokens: Map.put(state.tokens, new_token_id, new_token),
          active_tokens: MapSet.put(state.active_tokens, new_token_id),
          next_token_id: new_token_id + 1,
          pin_state: :pinned,
          pin_reason: :active_token
        }
    end
  end

  @doc """
  Terminates all active and waiting tokens, cancels timers, and marks
  the instance as terminated.
  """
  def terminate_all_tokens(state, _reason) do
    state = Enum.reduce(state.tokens, state, fn {token_id, token}, acc ->
      if Token.active?(token) or Token.waiting?(token) do
        token = Token.terminate(token)
        %{acc | tokens: Map.put(acc.tokens, token_id, token)}
      else
        acc
      end
    end)

    state = %{state |
      instance_state: :terminated,
      active_tokens: MapSet.new(),
      waiting_tokens: MapSet.new(),
      pin_state: :not_pinned,
      pin_reason: :none
    }

    # Cancel all timers
    Enum.each(state.timer_refs, fn {ref, _} ->
      Process.cancel_timer(ref)
    end)

    state
  end

  @doc """
  Classifies all tokens into active/waiting/completed sets based on
  token_wait_states map from event replay.
  """
  def classify_tokens(state, token_wait_states) do
    Enum.reduce(state.tokens, state, fn {token_id, token}, acc ->
      cond do
        # Token is in the open waits map - it's still waiting
        Map.has_key?(token_wait_states, token_id) ->
          wait_type = Map.get(token_wait_states, token_id)
          token = Token.set_waiting(token, wait_type)
          %{acc |
            tokens: Map.put(acc.tokens, token_id, token),
            waiting_tokens: MapSet.put(acc.waiting_tokens, token_id)
          }

        # Token is in a terminal state
        Token.terminal?(token) ->
          if token.state == :completed do
            %{acc | completed_tokens: MapSet.put(acc.completed_tokens, token_id)}
          else
            acc
          end

        # Token is active (not waiting, not terminal)
        true ->
          %{acc | active_tokens: MapSet.put(acc.active_tokens, token_id)}
      end
    end)
  end
end
