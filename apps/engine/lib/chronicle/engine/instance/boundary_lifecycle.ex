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
        timer_id: Map.get(info, :timer_id)
      }
    end)
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
end
