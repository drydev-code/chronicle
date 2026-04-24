defmodule DryDev.Workflow.Engine.Instance.WaitRegistry do
  @moduledoc """
  Functions for managing wait registrations within a process instance.
  Handles message/signal wait lookup, external task tracking,
  script/expression/rules wait tracking, call activity waits,
  timer ref management, and boundary event wait management.
  """

  alias DryDev.Workflow.Engine.Instance.TokenState

  @doc """
  Handles an incoming message delivery. Checks message_waits first,
  then falls back to message_boundaries. Returns {action, state} where
  action is :resumed, :boundary, or :ignored.
  """
  def handle_message(state, message_name, payload) do
    case Map.get(state.message_waits, message_name, []) do
      [] ->
        case Map.get(state.message_boundaries, message_name, []) do
          [] -> {:ignored, state}
          boundaries ->
            state = handle_interrupting_message_boundary(state, boundaries)
            {:boundary, state}
        end

      [token_id | rest] ->
        state = %{state | message_waits: Map.put(state.message_waits, message_name, rest)}
        state = TokenState.resume_token(state, token_id, {:message, message_name, payload})
        {:resumed, state}
    end
  end

  @doc """
  Handles an incoming signal delivery. Signals broadcast to all matching tokens.
  Returns state.
  """
  def handle_signal(state, signal_name) do
    signal_tokens = Map.get(state.signal_waits, signal_name, [])

    state = Enum.reduce(signal_tokens, state, fn token_id, acc ->
      TokenState.resume_token(acc, token_id, {:signal, signal_name})
    end)

    %{state | signal_waits: Map.delete(state.signal_waits, signal_name)}
  end

  @doc """
  Handles external task completion. Returns {:ok, state} or {:error, :not_found}.
  """
  def complete_external_task(state, task_id, payload, result) do
    case Map.get(state.external_tasks, task_id) do
      nil -> {:error, :not_found}
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
      nil -> {:error, :not_found}
      token_id ->
        state = TokenState.resume_token(state, token_id, {:error, error, retry?, backoff_ms})
        {:ok, state}
    end
  end

  @doc """
  Handles script/expression/rules result by ref lookup.
  Returns {:ok, state} or {:error, :not_found}.
  """
  def handle_script_result(state, ref, result) do
    case Map.get(state.script_waits, ref) do
      nil -> {:error, :not_found}
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
      nil -> {:error, :not_found}
      token_id ->
        state = %{state | call_wait_list: Map.delete(state.call_wait_list, child_id)}
        state = TokenState.resume_token(state, token_id, {:completed, completion_context, successful})
        {:ok, state}
    end
  end

  @doc """
  Handles timer elapsed for a regular intermediate timer.
  Returns {:resumed, state} or {:ignored, state}.
  State always has the timer_ref cleaned up.
  """
  def handle_timer_elapsed(state, token_id, timer_ref) do
    alias DryDev.Workflow.Engine.Token

    state = %{state | timer_refs: Map.delete(state.timer_refs, timer_ref)}

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
    alias DryDev.Workflow.Engine.Token

    state = %{state | timer_refs: Map.delete(state.timer_refs, timer_ref)}

    token = Map.get(state.tokens, token_id)
    if token && Token.waiting?(token) do
      state = TokenState.interrupt_token(state, token_id, boundary_node_id)
      {:resumed, state}
    else
      {:ignored, state}
    end
  end

  # --- Private helpers ---

  defp handle_interrupting_message_boundary(state, boundaries) do
    Enum.reduce(boundaries, state, fn {token_id, boundary_node}, acc ->
      TokenState.interrupt_token(acc, token_id, boundary_node.id)
    end)
  end
end
