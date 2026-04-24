defmodule Chronicle.Engine.Nodes.CallActivity do
  @moduledoc """
  Call Activity - starts subprocess, supports sync/async and sequential loops.
  """
  use Chronicle.Engine.Nodes.Node

  defstruct [
    :id, :key, :process_name, :keep_business_key, :as_async_call,
    :sequential_loop, :collection_name, :element_name, :result_variable,
    :inputs, :outputs, :boundary_events, :properties
  ]

  @impl true
  def simulation_barrier?(), do: true

  @impl true
  def process(context) do
    if context.simulation_mode do
      handle_simulation(context)
    else
      node = context.node
      call_params = build_call_params(context, node)
      NodeResult.call(call_params)
    end
  end

  @impl true
  def continue_after_wait(context) do
    continuation = context.token.context.continuation_context
    node = context.node

    case continuation do
      {:completed, _completion_context, _successful} ->
        if node.sequential_loop && has_more_iterations?(context) do
          NodeResult.step()
        else
          first_output = List.first(node.outputs || [])
          NodeResult.next(first_output)
        end

      {:canceled, next_node} ->
        NodeResult.next(next_node)

      _ ->
        first_output = List.first(node.outputs || [])
        NodeResult.next(first_output)
    end
  end

  defp build_call_params(context, node) do
    business_key = if node.keep_business_key, do: context.business_key, else: UUID.uuid4()

    element = if node.sequential_loop do
      collection = Map.get(context.token.parameters, node.collection_name, [])
      step = context.token.context.step
      Enum.at(collection, step)
    end

    %{
      process_name: node.process_name,
      business_key: business_key,
      tenant_id: context.tenant_id,
      parent_id: context.instance_id,
      parent_business_key: context.business_key,
      async: node.as_async_call || false,
      parameters: context.token.parameters,
      element: element,
      element_name: node.element_name,
      loop_index: context.token.context.step
    }
  end

  defp has_more_iterations?(context) do
    node = context.node
    collection = Map.get(context.token.parameters, node.collection_name, [])
    context.token.context.step + 1 < length(collection)
  end

  defp handle_simulation(context) do
    {event, _ctx} = ExecutionContext.next_simulation_event(context)
    case event do
      %Chronicle.Engine.PersistentData.CallStarted{} ->
        NodeResult.simulation_barrier_then_wait(:waiting_for_call)
      %Chronicle.Engine.PersistentData.CallCompleted{next_node: next} ->
        NodeResult.next(next)
      %Chronicle.Engine.PersistentData.CallCanceled{next_node: next} ->
        NodeResult.next(next)
      _ ->
        NodeResult.simulation_barrier_then_wait(:waiting_for_call)
    end
  end
end
