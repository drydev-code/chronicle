defmodule Chronicle.Engine.Instance.WaitRegistry do
  @moduledoc """
  Functions for managing wait registrations within a process instance.
  Handles message/signal wait lookup, external task tracking,
  script/expression/rules wait tracking, call activity waits,
  timer ref management, and boundary event wait management.
  """

  alias Chronicle.Engine.Instance.TokenState
  alias Chronicle.Engine.{Diagrams.Definition, MessageCorrelation, Nodes}

  @doc """
  Handles an incoming message delivery. Checks message_waits first,
  then falls back to message_boundaries. Returns {action, state} where
  action is :resumed, :boundary, or :ignored.
  """
  def handle_message(state, message_name, payload) do
    state
    |> matching_message_delivery(message_name, payload)
    |> handle_message_delivery(state, message_name, payload)
  end

  def matching_message_delivery(state, message_name, payload) do
    case matching_message_wait(state, message_name, payload) do
      nil ->
        matching_message_boundaries(state, message_name, payload)

      match ->
        match
    end
  end

  def handle_message_delivery({:wait, token_id, selected_node_id}, state, message_name, payload) do
    case Map.get(state.message_waits, message_name, []) do
      waits when is_list(waits) ->
        rest = List.delete(waits, token_id)

        new_waits =
          if rest == [] do
            Map.delete(state.message_waits, message_name)
          else
            Map.put(state.message_waits, message_name, rest)
          end

        state = %{state | message_waits: new_waits}
        state = remove_token_from_all_message_waits(state, token_id)
        state = remove_token_from_all_signal_waits(state, token_id)

        # Remove the per-token entry from the global :waits registry so
        # stale routes do not survive after consumption.
        unregister_message_wait(state, message_name, token_id)

        continuation =
          if selected_node_id do
            {:message, message_name, payload, selected_node_id}
          else
            {:message, message_name, payload}
          end

        state = TokenState.resume_token(state, token_id, continuation)
        {:resumed, state}
    end
  end

  def handle_message_delivery(
        {:boundaries, boundaries, interrupting_count},
        state,
        _message_name,
        _payload
      ) do
    {:boundary, handle_message_boundary(state, boundaries, interrupting_count)}
  end

  def handle_message_delivery(:ignored, state, _message_name, _payload), do: {:ignored, state}

  @doc """
  Handles an incoming signal delivery. Signals broadcast to all matching tokens.
  Returns state.
  """
  def handle_signal(state, signal_name) do
    signal_tokens = Map.get(state.signal_waits, signal_name, [])
    boundaries = Map.get(state.signal_boundaries, signal_name, [])
    ni_boundaries = Map.get(state.ni_signal_boundaries || %{}, signal_name, [])

    # Remove all per-token entries from the global :waits registry; the
    # in-memory signal_waits map is cleared below.
    unregister_signal_waits(state, signal_name, signal_tokens)

    state =
      Enum.reduce(signal_tokens, state, fn token_id, acc ->
        acc
        |> remove_token_from_all_message_waits(token_id)
        |> remove_token_from_all_signal_waits(token_id)
        |> TokenState.resume_token(token_id, {:signal, signal_name})
      end)

    state =
      Enum.reduce(boundaries, state, fn {token_id, boundary_node}, acc ->
        acc
        |> TokenState.trigger_boundary(token_id, boundary_node.id, true)
        |> cancel_boundary_registrations(token_id)
      end)

    Enum.reduce(ni_boundaries, state, fn {token_id, boundary_node}, acc ->
      TokenState.trigger_boundary(acc, token_id, boundary_node.id, false)
    end)
    |> Map.put(:signal_waits, Map.delete(state.signal_waits, signal_name))
  end

  @doc """
  Handles external task completion. Returns {:ok, state} or {:error, :not_found}.
  """
  def complete_external_task(state, task_id, payload, result) do
    case Map.get(state.external_tasks, task_id) do
      nil ->
        {:error, :not_found}

      token_id ->
        state = %{state | external_tasks: Map.delete(state.external_tasks, task_id)}
        state = TokenState.resume_token(state, token_id, {:complete, payload, result})
        {:ok, state, token_id}
    end
  end

  @doc """
  Handles external task error. Returns {:ok, state} or {:error, :not_found}.
  """
  def error_external_task(state, task_id, error, retry?, backoff_ms) do
    case Map.get(state.external_tasks, task_id) do
      nil ->
        {:error, :not_found}

      token_id ->
        state = %{state | external_tasks: Map.delete(state.external_tasks, task_id)}
        state = TokenState.resume_token(state, token_id, {:error, error, retry?, backoff_ms})
        {:ok, state}
    end
  end

  @doc """
  Cancels an open external task and resumes the owning token with a cancellation
  continuation.
  """
  def cancel_external_task(state, task_id, reason, continuation_node_id) do
    case Map.get(state.external_tasks, task_id) do
      nil ->
        state

      token_id ->
        state = %{state | external_tasks: Map.delete(state.external_tasks, task_id)}
        TokenState.resume_token(state, token_id, {:cancel, reason, continuation_node_id})
    end
  end

  @doc """
  Handles script/expression/rules result by ref lookup.
  Returns {:ok, state} or {:error, :not_found}.
  """
  def handle_script_result(state, ref, result) do
    case Map.get(state.script_waits, ref) do
      nil ->
        {:error, :not_found}

      token_id ->
        state = %{state | script_waits: Map.delete(state.script_waits, ref)}
        state = TokenState.resume_token(state, token_id, result)
        {:ok, state}
    end
  end

  @doc """
  Handles child process completion (CallActivity).
  Returns {:ok, state} or {:error, :not_found}.
  """
  def handle_child_completed(state, child_id, completion_context, successful) do
    case Map.get(state.call_wait_list, child_id) do
      nil ->
        {:error, :not_found}

      token_id ->
        state = %{state | call_wait_list: Map.delete(state.call_wait_list, child_id)}

        state =
          TokenState.resume_token(state, token_id, {:completed, completion_context, successful})

        {:ok, state}
    end
  end

  @doc """
  Cancels an open call wait and resumes the parent token.
  """
  def cancel_call(state, child_id, next_node) do
    case Map.get(state.call_wait_list, child_id) do
      nil ->
        state

      token_id ->
        state = %{state | call_wait_list: Map.delete(state.call_wait_list, child_id)}
        TokenState.resume_token(state, token_id, {:canceled, next_node})
    end
  end

  @doc """
  Handles timer elapsed for a regular intermediate timer.
  Returns {:resumed, state} or {:ignored, state}.
  State always has the timer_ref cleaned up.
  """
  def handle_timer_elapsed(state, token_id, timer_ref) do
    alias Chronicle.Engine.Token

    state = %{
      state
      | timer_refs: Map.delete(state.timer_refs, timer_ref),
        timer_ref_ids: Map.delete(state.timer_ref_ids || %{}, timer_ref)
    }

    token = Map.get(state.tokens, token_id)

    if token && Token.waiting?(token) do
      state = TokenState.resume_token(state, token_id, :timer_elapsed)
      {:resumed, state}
    else
      {:ignored, state}
    end
  end

  @doc """
  Handles boundary timer elapsed.
  Returns {:resumed, state} or {:ignored, state}.
  State always has the timer_ref cleaned up.
  """
  def handle_boundary_timer_elapsed(state, token_id, boundary_node_id, timer_ref) do
    alias Chronicle.Engine.Token

    state = %{
      state
      | timer_refs: Map.delete(state.timer_refs, timer_ref),
        timer_ref_ids: Map.delete(state.timer_ref_ids || %{}, timer_ref)
    }

    token = Map.get(state.tokens, token_id)

    if token && Token.waiting?(token) do
      interrupting? = boundary_interrupting?(state, token_id, boundary_node_id)
      state = TokenState.trigger_boundary(state, token_id, boundary_node_id, interrupting?)
      {:resumed, state}
    else
      {:ignored, state}
    end
  end

  @doc """
  Removes all `:waits` Registry entries owned by the current process for
  the given key whose value equals `token_id`. The `:waits` Registry is
  `:duplicate`, so multiple entries may share a key; we match by value.
  """
  def unregister(registry, key, token_id) do
    Registry.unregister_match(registry, key, token_id)
    :ok
  end

  @doc """
  Removes all boundary wait registrations attached to a token. The caller is
  responsible for appending durable BoundaryEventCancelled events before this
  mutates the in-memory registries.
  """
  def cancel_boundary_registrations(state, token_id, except_boundary_node_id \\ nil) do
    infos =
      state.boundary_index
      |> Map.get(token_id, [])
      |> Enum.reject(&(&1.boundary_node_id == except_boundary_node_id))

    Enum.each(infos, fn
      %{timer_ref: ref} when not is_nil(ref) ->
        Process.cancel_timer(ref)

      _ ->
        :ok
    end)

    state =
      Enum.reduce(infos, state, fn info, acc ->
        acc
        |> remove_boundary_message_registration(token_id, info)
        |> remove_boundary_signal_registration(token_id, info)
        |> remove_boundary_timer_registration(info)
      end)

    remaining =
      state.boundary_index
      |> Map.get(token_id, [])
      |> Enum.filter(&(&1.boundary_node_id == except_boundary_node_id))

    boundary_index =
      if remaining == [] do
        Map.delete(state.boundary_index, token_id)
      else
        Map.put(state.boundary_index, token_id, remaining)
      end

    %{state | boundary_index: boundary_index}
  end

  @doc """
  Removes the boundary registration that has just triggered without emitting a
  cancellation. This is mainly for one-shot non-interrupting timers: the
  boundary fired, so replay should not restore the same timer again.
  """
  def close_triggered_boundary_registration(state, token_id, boundary_node_id) do
    infos =
      state.boundary_index
      |> Map.get(token_id, [])
      |> Enum.filter(&(&1.boundary_node_id == boundary_node_id))

    state =
      Enum.reduce(infos, state, fn info, acc ->
        acc
        |> remove_boundary_message_registration(token_id, info)
        |> remove_boundary_signal_registration(token_id, info)
        |> remove_boundary_timer_registration(info)
      end)

    remaining =
      state.boundary_index
      |> Map.get(token_id, [])
      |> Enum.reject(&(&1.boundary_node_id == boundary_node_id))

    boundary_index =
      if remaining == [] do
        Map.delete(state.boundary_index, token_id)
      else
        Map.put(state.boundary_index, token_id, remaining)
      end

    %{state | boundary_index: boundary_index}
  end

  @doc """
  Cancels open non-boundary timers for a token after their `TimerCanceled`
  events have been persisted. Boundary timers are left for boundary lifecycle
  cleanup so sibling `BoundaryEventCancelled` semantics stay explicit.
  """
  def cancel_activity_timer_registrations(state, token_id) do
    boundary_refs =
      state.boundary_index
      |> Map.get(token_id, [])
      |> Enum.filter(&(&1.type == :timer))
      |> Enum.map(&Map.get(&1, :timer_ref))
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    {refs, keep_refs} =
      Enum.split_with(state.timer_refs || %{}, fn {ref, owner_token_id} ->
        owner_token_id == token_id and not MapSet.member?(boundary_refs, ref)
      end)

    Enum.each(refs, fn {ref, _token_id} -> Process.cancel_timer(ref) end)

    dropped_refs = Enum.map(refs, &elem(&1, 0))

    %{
      state
      | timer_refs: Map.new(keep_refs),
        timer_ref_ids: Map.drop(state.timer_ref_ids || %{}, dropped_refs)
    }
  end

  # --- Private helpers ---

  defp unregister_message_wait(state, message_name, token_id) do
    key = {state.tenant_id, :message, message_name, state.business_key}
    unregister(:waits, key, token_id)
  end

  defp unregister_signal_waits(state, signal_name, token_ids) do
    key = {state.tenant_id, :signal, signal_name}

    Enum.each(token_ids, fn token_id ->
      unregister(:waits, key, token_id)
    end)
  end

  defp matching_message_wait(state, message_name, payload) do
    state.message_waits
    |> Map.get(message_name, [])
    |> Enum.find_value(fn token_id ->
      token = Map.get(state.tokens, token_id)

      case matching_wait_node(state, token, message_name, payload) do
        {:ok, selected_node_id} -> {:wait, token_id, selected_node_id}
        :error -> nil
      end
    end)
  end

  defp matching_wait_node(_state, nil, _message_name, _payload), do: :error

  defp matching_wait_node(state, token, message_name, payload) do
    node = Definition.get_node(state.definition, token.current_node)

    case node do
      %Nodes.Gateway{kind: :event_based} ->
        token.context[:event_gateway_candidates]
        |> List.wrap()
        |> Enum.filter(&(&1[:type] == :message and &1[:name] == message_name))
        |> Enum.find_value(fn candidate ->
          branch = Definition.get_node(state.definition, candidate[:node_id])

          if message_node_matches?(branch, token, message_name, payload) do
            {:ok, candidate[:node_id]}
          end
        end) || :error

      node ->
        if message_node_matches?(node, token, message_name, payload) do
          {:ok, nil}
        else
          :error
        end
    end
  end

  defp matching_message_boundaries(state, message_name, payload) do
    interrupting =
      state.message_boundaries
      |> Map.get(message_name, [])
      |> Enum.filter(fn {token_id, boundary_node} ->
        token = Map.get(state.tokens, token_id)
        message_node_matches?(boundary_node, token, message_name, payload)
      end)

    non_interrupting =
      (state.ni_message_boundaries || %{})
      |> Map.get(message_name, [])
      |> Enum.filter(fn {token_id, boundary_node} ->
        token = Map.get(state.tokens, token_id)
        message_node_matches?(boundary_node, token, message_name, payload)
      end)

    case interrupting ++ non_interrupting do
      [] -> :ignored
      boundaries -> {:boundaries, boundaries, length(interrupting)}
    end
  end

  defp message_node_matches?(nil, _token, _message_name, _payload), do: false
  defp message_node_matches?(_node, nil, _message_name, _payload), do: false

  defp message_node_matches?(node, token, message_name, payload) do
    MessageCorrelation.matches?(
      node,
      payload,
      Map.put(token.parameters || %{}, "messageName", message_name)
    )
  end

  defp handle_message_boundary(state, all_boundaries, interrupting_count) do
    {interrupting_boundaries, non_interrupting_boundaries} =
      Enum.split(all_boundaries, interrupting_count)

    state =
      Enum.reduce(interrupting_boundaries, state, fn {token_id, boundary_node}, acc ->
        acc
        |> TokenState.trigger_boundary(token_id, boundary_node.id, true)
        |> cancel_boundary_registrations(token_id)
      end)

    Enum.reduce(non_interrupting_boundaries, state, fn {token_id, boundary_node}, acc ->
      TokenState.trigger_boundary(acc, token_id, boundary_node.id, false)
    end)
  end

  defp remove_token_from_all_message_waits(state, token_id) do
    waits =
      state.message_waits
      |> Enum.reduce(%{}, fn {name, token_ids}, acc ->
        remaining = List.delete(token_ids, token_id)
        if remaining == [], do: acc, else: Map.put(acc, name, remaining)
      end)

    %{state | message_waits: waits}
  end

  defp remove_token_from_all_signal_waits(state, token_id) do
    waits =
      state.signal_waits
      |> Enum.reduce(%{}, fn {name, token_ids}, acc ->
        remaining = List.delete(token_ids, token_id)
        if remaining == [], do: acc, else: Map.put(acc, name, remaining)
      end)

    %{state | signal_waits: waits}
  end

  defp remove_boundary_message_registration(state, token_id, %{
         type: :message,
         name: name,
         boundary_node_id: boundary_id
       }) do
    Registry.unregister_match(
      :waits,
      {state.tenant_id, :message, name, state.business_key},
      {:boundary, token_id, boundary_id}
    )

    %{
      state
      | message_boundaries:
          remove_boundary_from_waits(state.message_boundaries, name, token_id, boundary_id),
        ni_message_boundaries:
          remove_boundary_from_waits(
            state.ni_message_boundaries || %{},
            name,
            token_id,
            boundary_id
          )
    }
  end

  defp remove_boundary_message_registration(state, _token_id, _info), do: state

  defp remove_boundary_signal_registration(state, token_id, %{
         type: :signal,
         name: name,
         boundary_node_id: boundary_id
       }) do
    Registry.unregister_match(
      :waits,
      {state.tenant_id, :signal, name},
      {:boundary, token_id, boundary_id}
    )

    %{
      state
      | signal_boundaries:
          remove_boundary_from_waits(state.signal_boundaries, name, token_id, boundary_id),
        ni_signal_boundaries:
          remove_boundary_from_waits(
            state.ni_signal_boundaries || %{},
            name,
            token_id,
            boundary_id
          )
    }
  end

  defp remove_boundary_signal_registration(state, _token_id, _info), do: state

  defp remove_boundary_timer_registration(state, %{type: :timer, timer_ref: ref})
       when not is_nil(ref) do
    %{
      state
      | timer_refs: Map.delete(state.timer_refs || %{}, ref),
        timer_ref_ids: Map.delete(state.timer_ref_ids || %{}, ref)
    }
  end

  defp remove_boundary_timer_registration(state, _info), do: state

  defp remove_boundary_from_waits(waits, name, token_id, boundary_id) do
    updated =
      waits
      |> Map.get(name, [])
      |> Enum.reject(fn {tid, boundary} -> tid == token_id and boundary.id == boundary_id end)

    if updated == [] do
      Map.delete(waits, name)
    else
      Map.put(waits, name, updated)
    end
  end

  defp boundary_interrupting?(state, token_id, boundary_node_id) do
    infos = get_in(state.boundary_index || %{}, [token_id]) || []

    case Enum.find(infos, &(&1.boundary_node_id == boundary_node_id)) do
      nil -> true
      info -> Map.get(info, :interrupting, true)
    end
  end
end
