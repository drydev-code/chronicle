defmodule DryDev.Workflow.Engine.Nodes.ExternalTask do
  @moduledoc """
  External Activity Task - Service Task / User Task.
  Returns WaitForExternalTask, handles complete/error/cancel.
  """
  use DryDev.Workflow.Engine.Nodes.Node

  @type kind :: :user | :service

  defstruct [
    :id, :key, :kind, :result_variable, :error_behaviour,
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
      task_id = UUID.uuid4()
      NodeResult.wait_for_external_task(task_id, node.kind)
    end
  end

  @impl true
  def continue_after_wait(context) do
    continuation = context.token.context.continuation_context

    case continuation do
      {:complete, payload, result} ->
        handle_completion(context, payload, result)

      {:error, error_data, retry?, backoff_ms} ->
        handle_error(context, error_data, retry?, backoff_ms)

      {:cancel, _reason, continuation_node_id} ->
        NodeResult.next(continuation_node_id)
    end
  end

  defp handle_completion(context, payload, _result) do
    node = context.node
    # Store payload under result_variable in token params
    merged = if node.result_variable && node.result_variable != "" do
      Map.put(context.token.parameters, node.result_variable, payload)
    else
      # No result_variable: merge payload directly if it's a map
      case payload do
        p when is_map(p) -> Map.merge(context.token.parameters, p)
        _ -> context.token.parameters
      end
    end
    first_output = List.first(node.outputs || [])
    if first_output, do: NodeResult.next_with_params(first_output, merged), else: NodeResult.complete(%DryDev.Workflow.Engine.CompletionData.Blank{})
  end

  defp handle_error(context, error_data, retry?, backoff_ms) do
    node = context.node
    error_behaviour = node.error_behaviour || :fail

    case error_behaviour do
      :retry when retry? ->
        NodeResult.retry(backoff_ms)

      :ignore ->
        first_output = List.first(node.outputs || [])
        NodeResult.next(first_output)

      _ ->
        # Fail: propagate to error boundary or crash
        boundary = DryDev.Workflow.Engine.Nodes.Activity.get_boundary_event_to_error(node, error_data)
        if boundary do
          NodeResult.next(boundary.id)
        else
          {:crash, error_data}
        end
    end
  end

  defp handle_simulation(context) do
    {event, _ctx} = ExecutionContext.next_simulation_event(context)
    case event do
      %DryDev.Workflow.Engine.PersistentData.ExternalTaskCreation{} ->
        NodeResult.simulation_barrier_then_wait(:waiting_for_external_task)
      %DryDev.Workflow.Engine.PersistentData.ExternalTaskCompletion{successful: true, next_node: next} ->
        NodeResult.next(next)
      %DryDev.Workflow.Engine.PersistentData.ExternalTaskCompletion{successful: false} ->
        NodeResult.simulation_barrier_then_execute()
      %DryDev.Workflow.Engine.PersistentData.ExternalTaskCancellation{continuation_node_id: node_id} ->
        NodeResult.next(node_id)
      _ ->
        NodeResult.simulation_barrier_then_wait(:waiting_for_external_task)
    end
  end
end
