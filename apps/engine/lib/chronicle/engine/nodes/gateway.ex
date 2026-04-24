defmodule Chronicle.Engine.Nodes.Gateway do
  @moduledoc """
  All gateway types: Parallel, Exclusive (Xor), Inclusive.
  Handles both fork and merge behavior.
  """
  use Chronicle.Engine.Nodes.Node

  @type kind :: :parallel | :exclusive | :inclusive

  defstruct [
    :id, :key, :kind, :is_merging, :expressions, :default_path,
    :inputs, :outputs, :properties
  ]

  @impl true
  def process(context) do
    node = context.node

    if node.is_merging do
      process_merge(context, node)
    else
      process_fork(context, node)
    end
  end

  @impl true
  def continue_after_wait(context) do
    node = context.node
    raw_continuation = context.token.context.continuation_context
    continuation = normalize_expression_results(raw_continuation)

    case node.kind do
      :exclusive ->
        # Expressions evaluated, select single path
        fork_xor(node, continuation)

      :inclusive ->
        # Expressions evaluated, select all true paths
        fork_inclusive(node, continuation)

      :parallel ->
        # Join completed
        first_output = List.first(node.outputs || [])
        NodeResult.next(first_output)
    end
  end

  # Normalize expression results from ScriptPool format to [{node_id, result}] tuples
  defp normalize_expression_results({:ok, results}) when is_list(results) do
    normalize_expression_results(results)
  end
  defp normalize_expression_results(results) when is_list(results) do
    Enum.map(results, fn
      %{"node_id" => node_id, "result" => result} -> {node_id, result}
      {_node_id, _result} = tuple -> tuple
      other -> {0, other}
    end)
  end
  defp normalize_expression_results(other), do: [{0, other}]

  # Fork behavior
  defp process_fork(_context, %{kind: :parallel} = node) do
    # All output paths taken immediately
    NodeResult.fork(node.outputs, [])
  end

  defp process_fork(context, %{kind: kind} = node) when kind in [:exclusive, :inclusive] do
    if map_size(node.expressions || %{}) > 0 do
      # Need to evaluate expressions
      ref = make_ref()
      expressions = Enum.map(node.expressions || %{}, fn {node_id, expr} -> {node_id, expr} end)

      Chronicle.Engine.Scripting.ScriptPool.execute_expressions(
        ref,
        expressions,
        context.token.parameters,
        context.instance_pid
      )

      NodeResult.wait_for_expressions(ref)
    else
      # No expressions, take default or first path
      path = effective_default(node) || List.first(node.outputs || [])
      NodeResult.next(path)
    end
  end

  # Merge behavior
  defp process_merge(_context, %{kind: :parallel}) do
    NodeResult.wait_for_join()
  end

  defp process_merge(context, %{kind: :exclusive}) do
    # Exclusive merge: pass-through, no synchronization
    first_output = List.first(context.node.outputs || [])
    NodeResult.next(first_output)
  end

  defp process_merge(_context, %{kind: :inclusive}) do
    NodeResult.wait_for_join()
  end

  defp fork_xor(node, expression_results) do
    # Select FIRST true path, or default
    selected = Enum.find(expression_results, fn {_node_id, result} -> result == true end)

    case selected do
      {node_id, _} -> NodeResult.next(node_id)
      nil ->
        path = effective_default(node) || List.first(node.outputs || [])
        NodeResult.next(path)
    end
  end

  defp fork_inclusive(node, expression_results) do
    # Select ALL true paths
    true_paths = expression_results
      |> Enum.filter(fn {_node_id, result} -> result == true end)
      |> Enum.map(fn {node_id, _} -> node_id end)

    case true_paths do
      [] ->
        path = effective_default(node) || List.first(node.outputs || [])
        NodeResult.next(path)
      [single] ->
        NodeResult.next(single)
      paths ->
        NodeResult.fork(paths, [])
    end
  end

  # 0 means "no default path" in the BPMN JSON format
  defp effective_default(%{default_path: 0}), do: nil
  defp effective_default(%{default_path: dp}), do: dp
  defp effective_default(_), do: nil
end
