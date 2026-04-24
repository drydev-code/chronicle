defmodule Chronicle.Engine.Nodes.Gateway do
  @moduledoc """
  All gateway types: Parallel, Exclusive (Xor), Inclusive, Event-based.
  Handles both fork and merge behavior.
  """
  use Chronicle.Engine.Nodes.Node

  @type kind :: :parallel | :exclusive | :inclusive | :event_based

  defstruct [
    :id, :key, :kind, :is_merging, :expressions, :default_path,
    :inputs, :outputs, :properties
  ]

  @impl true
  def process(context) do
    node = context.node

    cond do
      node.kind == :event_based -> process_event_based(context, node)
      node.is_merging -> process_merge(context, node)
      true -> process_fork(context, node)
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

      :event_based ->
        continue_event_based(context, node)
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

  defp process_event_based(context, node) do
    candidates_or_errors =
      Enum.map(node.outputs || [], fn node_id ->
        branch = Chronicle.Engine.Diagrams.Definition.get_node(context.definition, node_id)

        case event_candidate(branch, context.token.parameters) do
          nil -> {:error, node_id, branch_type(branch)}
          candidate -> {:ok, candidate}
        end
      end)

    errors = Enum.filter(candidates_or_errors, &match?({:error, _, _}, &1))

    cond do
      errors != [] ->
        {:crash, {:event_based_gateway_unsupported_branches, errors}}

      candidates_or_errors == [] ->
        {:crash, :event_based_gateway_has_no_supported_events}

      true ->
        candidates = Enum.map(candidates_or_errors, fn {:ok, candidate} -> candidate end)
        {:wait_for_event_gateway, candidates}
    end
  end

  defp continue_event_based(context, node) do
    trigger = context.token.context.continuation_context
    selected = select_event_candidate(context.definition, node.outputs || [], trigger, context.token.context[:event_gateway_candidates] || [])

    case selected do
      nil ->
        {:crash, {:event_gateway_no_matching_trigger, trigger}}

      selected_node ->
        first_output = List.first(selected_node.outputs || [])
        {:event_gateway_resolved, trigger, selected_node.id, first_output}
    end
  end

  defp event_candidate(%Chronicle.Engine.Nodes.IntermediateCatch.MessageEvent{} = node, params),
    do: %{type: :message, name: resolve_message_name(node.message, params), node_id: node.id}

  defp event_candidate(%Chronicle.Engine.Nodes.Tasks.ReceiveTask{} = node, params),
    do: %{type: :message, name: resolve_message_name(node.message, params), node_id: node.id}

  defp event_candidate(%Chronicle.Engine.Nodes.IntermediateCatch.SignalEvent{} = node, _params),
    do: %{type: :signal, name: node.signal, node_id: node.id}

  defp event_candidate(%Chronicle.Engine.Nodes.IntermediateCatch.TimerEvent{} = node, _params),
    do: %{type: :timer, node_id: node.id, timer_config: node.timer_config}

  defp event_candidate(_, _params), do: nil

  defp branch_type(nil), do: nil
  defp branch_type(branch), do: branch.__struct__ |> Module.split() |> List.last()

  defp select_event_candidate(definition, _outputs, {:message, name, _payload}, candidates) do
    case Enum.find(candidates, &(&1[:type] == :message and &1[:name] == name)) do
      %{node_id: node_id} -> Chronicle.Engine.Diagrams.Definition.get_node(definition, node_id)
      _ -> nil
    end
  end

  defp select_event_candidate(definition, _outputs, {:signal, name}, candidates) do
    case Enum.find(candidates, &(&1[:type] == :signal and &1[:name] == name)) do
      %{node_id: node_id} -> Chronicle.Engine.Diagrams.Definition.get_node(definition, node_id)
      _ -> nil
    end
  end

  defp select_event_candidate(definition, _outputs, :timer_elapsed, candidates) do
    case Enum.find(candidates, &(&1[:type] == :timer)) do
      %{node_id: node_id} -> Chronicle.Engine.Diagrams.Definition.get_node(definition, node_id)
      _ -> nil
    end
  end

  defp select_event_candidate(_definition, _outputs, _trigger, _candidates), do: nil

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

  defp resolve_message_name(%{static_text: text, variable_content: nil}, _params) when not is_nil(text), do: text
  defp resolve_message_name(%{static_text: text}, _params) when not is_nil(text), do: text
  defp resolve_message_name(%{name: name}, _params), do: name
  defp resolve_message_name(name, _params) when is_binary(name), do: name
  defp resolve_message_name(_, _params), do: nil
end
