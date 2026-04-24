defmodule Chronicle.Engine.Instance.BoundaryLifecycle do
  @moduledoc """
  Helpers for deriving durable boundary lifecycle events before mutating
  in-memory wait registries.
  """

  alias Chronicle.Engine.PersistentData

  @doc """
  Returns `BoundaryEventCancelled` events for every open boundary registration
  on `token_id`, optionally excluding the boundary that is currently firing.
  """
  def cancellation_events(state, token_id, except_boundary_node_id \\ nil) do
    token = Map.get(state.tokens, token_id)

    state.boundary_index
    |> Map.get(token_id, [])
    |> Enum.reject(&(&1.boundary_node_id == except_boundary_node_id))
    |> Enum.map(fn info ->
      %PersistentData.BoundaryEventCancelled{
        token: token_id,
        family: token && token.family,
        current_node: token && token.current_node,
        boundary_node_id: info.boundary_node_id,
        boundary_type: info.type,
        name: Map.get(info, :name),
        condition: Map.get(info, :condition),
        timer_id: Map.get(info, :timer_id)
      }
    end)
  end

  @doc """
  Returns `TimerCanceled` events for open non-boundary timers owned by the
  token. This is used when an interrupting boundary wins while the activity is
  parked on a retry timer: the retry wait must be durably closed before the
  boundary continuation mutates in-memory timers.
  """
  def activity_timer_cancellation_events(state, token_id) do
    token = Map.get(state.tokens, token_id)
    boundary_timer_refs = boundary_timer_refs(state, token_id)

    state.timer_refs
    |> Enum.reject(fn {ref, owner_token_id} ->
      owner_token_id != token_id or MapSet.member?(boundary_timer_refs, ref)
    end)
    |> Enum.map(fn {ref, _owner_token_id} ->
      %PersistentData.TimerCanceled{
        token: token_id,
        family: token && token.family,
        current_node: token && token.current_node,
        retry_counter: token && token.context[:retries],
        timer_id: Map.get(state.timer_ref_ids || %{}, ref)
      }
    end)
    |> Enum.reject(&is_nil(&1.timer_id))
  end

  @doc """
  Returns the open boundary metadata for a token/boundary pair.
  """
  def boundary_info(state, token_id, boundary_node_id) do
    state.boundary_index
    |> Map.get(token_id, [])
    |> Enum.find(&(&1.boundary_node_id == boundary_node_id))
  end

  @doc """
  Builds the durable trigger event for an open boundary registration.
  """
  def trigger_event(state, token_id, boundary_node_id) do
    token = Map.get(state.tokens, token_id)
    info = boundary_info(state, token_id, boundary_node_id)

    %PersistentData.BoundaryEventTriggered{
      token: token_id,
      family: token && token.family,
      current_node: token && token.current_node,
      boundary_node_id: boundary_node_id,
      boundary_type: info && info.type,
      interrupting: info && info.interrupting != false,
      name: info && Map.get(info, :name),
      condition: info && Map.get(info, :condition),
      timer_id: info && Map.get(info, :timer_id),
      triggered_at: System.system_time(:millisecond)
    }
  end

  def interrupting?(state, token_id, boundary_node_id) do
    case boundary_info(state, token_id, boundary_node_id) do
      nil -> true
      info -> info.interrupting != false
    end
  end

  defp boundary_timer_refs(state, token_id) do
    state.boundary_index
    |> Map.get(token_id, [])
    |> Enum.filter(&(&1.type == :timer))
    |> Enum.map(&Map.get(&1, :timer_ref))
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end
end
