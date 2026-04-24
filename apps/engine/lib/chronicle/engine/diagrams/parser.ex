defmodule Chronicle.Engine.Diagrams.Parser do
  @moduledoc """
  Parse JSON/BPJS diagram format into ProcessDefinition.
  Supports both PascalCase (.NET) and camelCase JSON formats.
  """
  alias Chronicle.Engine.Diagrams.Definition
  alias Chronicle.Engine.Nodes

  def parse(json_string) when is_binary(json_string) do
    json_string = String.trim_leading(json_string, "\uFEFF")

    case Jason.decode(json_string) do
      {:ok, data} -> parse_definition(data)
      {:error, reason} -> {:error, {:parse_error, reason}}
    end
  end

  def parse_definition(data) when is_map(data) do
    data = normalize_keys(data)
    processes = Map.get(data, "processes", [data])

    definitions = Enum.map(processes, fn process ->
      nodes = parse_nodes(Map.get(process, "nodes", []))
      connections = parse_connections(Map.get(process, "connections", []))
      reverse_connections = build_reverse_connections(connections)
      start_events = find_start_events(nodes)
      merging = find_merging_gateways(nodes)

      # Wire outputs/inputs to each node
      nodes_with_outputs = Enum.into(nodes, %{}, fn {id, node} ->
        outputs = Map.get(connections, id, [])
        inputs = Map.get(reverse_connections, id, [])
        node = node
          |> Map.put(:outputs, outputs)
          |> Map.put(:inputs, inputs)
        {id, node}
      end)

      %Definition{
        name: Map.get(process, "name", "unknown"),
        version: Map.get(process, "version"),
        tenant: Map.get(process, "tenant"),
        nodes: nodes_with_outputs,
        connections: connections,
        reverse_connections: reverse_connections,
        start_events: start_events,
        merging_gateways: merging,
        recursive_connections: parse_recursive_connections(Map.get(process, "recursiveConnections", []))
      }
    end)

    case definitions do
      [single] -> {:ok, single}
      multiple -> {:ok, multiple}
    end
  end

  # -- Key normalization: PascalCase -> camelCase --

  defp normalize_keys(data) when is_map(data) do
    Enum.into(data, %{}, fn {k, v} ->
      {to_camel_case(k), normalize_keys(v)}
    end)
  end
  defp normalize_keys(data) when is_list(data), do: Enum.map(data, &normalize_keys/1)
  defp normalize_keys(data), do: data

  defp to_camel_case(<<first, rest::binary>>) when first >= ?A and first <= ?Z do
    <<first + 32, rest::binary>>
  end
  defp to_camel_case(key), do: key

  # -- Node type normalization: .NET names -> internal names --

  defp normalize_type("TerminateEndEvent"), do: "terminationEndEvent"
  defp normalize_type("XorGateway"), do: "exclusiveGateway"
  defp normalize_type("ServiceTask"), do: "externalTask"
  defp normalize_type("UserTask"), do: "userTask"
  defp normalize_type("FormStartEvent"), do: "blankStartEvent"
  defp normalize_type("ApiStartEvent"), do: "blankStartEvent"
  defp normalize_type("UiStartEvent"), do: "blankStartEvent"
  defp normalize_type("ErrorStartEvent"), do: "blankStartEvent"
  defp normalize_type("EscalationStartEvent"), do: "blankStartEvent"
  defp normalize_type("SubProcess"), do: "callActivity"
  defp normalize_type("IntermediateThrowErrorEvent"), do: "intermediateThrowErrorEvent"
  defp normalize_type("IntermediateThrowEscalationEvent"), do: "intermediateThrowEscalationEvent"
  defp normalize_type(<<first, rest::binary>>) when first >= ?A and first <= ?Z do
    <<first + 32, rest::binary>>
  end
  defp normalize_type(type), do: type

  # -- Node parsing --

  defp parse_nodes(nodes_data) do
    Enum.into(nodes_data, %{}, fn node_data ->
      id = Map.get(node_data, "id")
      node = parse_node(node_data)
      {id, node}
    end)
  end

  defp parse_node(%{"type" => original_type} = data) do
    type = normalize_type(original_type)
    id = Map.get(data, "id")
    key = Map.get(data, "key")
    properties = Map.get(data, "properties") || extract_extension_properties(data)
    base = %{id: id, key: key, properties: properties}

    case type do
      t when t in ~w(blankStartEvent messageStartEvent signalStartEvent timerStartEvent) ->
        parse_start_event(t, base, data, original_type)

      t when t in ~w(blankEndEvent errorEndEvent messageEndEvent signalEndEvent escalationEndEvent terminationEndEvent) ->
        parse_end_event(t, base, data)

      t when t in ~w(scriptTask externalTask userTask rulesTask) ->
        parse_task_node(t, base, data)

      t when t in ~w(parallelGateway exclusiveGateway inclusiveGateway) ->
        parse_gateway_node(t, base, data)

      t when t in ~w(intermediateTimerEvent intermediateCatchTimerEvent intermediateCatchMessageEvent intermediateCatchSignalEvent) ->
        parse_intermediate_catch(t, base, data)

      t when t in ~w(intermediateThrowMessageEvent intermediateThrowSignalEvent intermediateThrowErrorEvent intermediateThrowEscalationEvent) ->
        parse_intermediate_throw(t, base, data)

      t when t in ~w(timerBoundaryEvent messageBoundaryEvent signalBoundaryEvent errorBoundaryEvent escalationBoundaryEvent nonInterruptingTimerBoundaryEvent nonInterruptingMessageBoundaryEvent nonInterruptingSignalBoundaryEvent) ->
        parse_boundary_event(t, base, data)

      "callActivity" ->
        parse_call_activity(base, data)

      _ ->
        %{id: id, key: key, type: type, properties: properties}
    end
  end

  # -- Start event parsers --

  defp parse_start_event("blankStartEvent", base, data, original_type) do
    %Nodes.StartEvents.BlankStartEvent{
      id: base.id, key: base.key,
      kind: parse_start_kind(data, original_type),
      properties: base.properties
    }
  end

  defp parse_start_event("messageStartEvent", base, data, _original_type) do
    %Nodes.StartEvents.MessageStartEvent{
      id: base.id, key: base.key,
      message: Map.get(data, "message"),
      properties: base.properties
    }
  end

  defp parse_start_event("signalStartEvent", base, data, _original_type) do
    %Nodes.StartEvents.SignalStartEvent{
      id: base.id, key: base.key,
      signal: Map.get(data, "signal"),
      properties: base.properties
    }
  end

  defp parse_start_event("timerStartEvent", base, data, _original_type) do
    %Nodes.StartEvents.TimerStartEvent{
      id: base.id, key: base.key,
      timer: parse_timer(data),
      properties: base.properties
    }
  end

  # -- End event parsers --

  defp parse_end_event("blankEndEvent", base, data) do
    export_all = Map.get(data, "exportAll", false)
    props = if export_all, do: Map.put(base.properties, "exportAll", true), else: base.properties
    %Nodes.EndEvents.BlankEndEvent{id: base.id, key: base.key, properties: props}
  end

  defp parse_end_event("errorEndEvent", base, data) do
    %Nodes.EndEvents.ErrorEndEvent{
      id: base.id, key: base.key,
      error_message: Map.get(data, "errorMessage") || Map.get(data, "message"),
      error_object: Map.get(data, "errorObject") || Map.get(data, "error"),
      properties: base.properties
    }
  end

  defp parse_end_event("messageEndEvent", base, data) do
    %Nodes.EndEvents.MessageEndEvent{
      id: base.id, key: base.key,
      message: parse_message(data),
      properties: base.properties
    }
  end

  defp parse_end_event("signalEndEvent", base, data) do
    %Nodes.EndEvents.SignalEndEvent{
      id: base.id, key: base.key,
      signal: Map.get(data, "signal"),
      properties: base.properties
    }
  end

  defp parse_end_event("escalationEndEvent", base, data) do
    %Nodes.EndEvents.EscalationEndEvent{
      id: base.id, key: base.key,
      escalation: Map.get(data, "escalation"),
      properties: base.properties
    }
  end

  defp parse_end_event("terminationEndEvent", base, data) do
    %Nodes.EndEvents.TerminationEndEvent{
      id: base.id, key: base.key,
      reason: Map.get(data, "reason"),
      properties: base.properties
    }
  end

  # -- Task node parsers --

  defp parse_task_node("scriptTask", base, data) do
    %Nodes.ScriptTask{
      id: base.id, key: base.key,
      script: Map.get(data, "script"),
      boundary_events: Map.get(data, "boundaryEvents", []),
      properties: base.properties
    }
  end

  defp parse_task_node("externalTask", base, data) do
    kind = case Map.get(data, "kind") do
      "user" -> :user
      "service" -> :service
      _ -> :service
    end

    %Nodes.ExternalTask{
      id: base.id, key: base.key, kind: kind,
      result_variable: Map.get(data, "resultVariable"),
      error_behaviour: parse_error_behaviour(data),
      boundary_events: Map.get(data, "boundaryEvents", []),
      properties: base.properties
    }
  end

  defp parse_task_node("userTask", base, data) do
    %Nodes.ExternalTask{
      id: base.id, key: base.key, kind: :user,
      result_variable: Map.get(data, "resultVariable"),
      error_behaviour: parse_error_behaviour(data),
      boundary_events: Map.get(data, "boundaryEvents", []),
      properties: base.properties
    }
  end

  defp parse_task_node("rulesTask", base, data) do
    %Nodes.RulesTask{
      id: base.id, key: base.key,
      dmn_name: Map.get(data, "dmnName"),
      return_variable: Map.get(data, "returnVariable"),
      boundary_events: Map.get(data, "boundaryEvents", []),
      properties: base.properties
    }
  end

  # -- Gateway parsers --

  defp parse_gateway_node("parallelGateway", base, data) do
    %Nodes.Gateway{
      id: base.id, key: base.key, kind: :parallel,
      is_merging: Map.get(data, "isMerging", false),
      properties: base.properties
    }
  end

  defp parse_gateway_node("exclusiveGateway", base, data) do
    %Nodes.Gateway{
      id: base.id, key: base.key, kind: :exclusive,
      is_merging: Map.get(data, "isMerging", false),
      expressions: parse_expressions(data),
      default_path: Map.get(data, "defaultPath"),
      properties: base.properties
    }
  end

  defp parse_gateway_node("inclusiveGateway", base, data) do
    %Nodes.Gateway{
      id: base.id, key: base.key, kind: :inclusive,
      is_merging: Map.get(data, "isMerging", false),
      expressions: parse_expressions(data),
      default_path: Map.get(data, "defaultPath"),
      properties: base.properties
    }
  end

  # -- Call activity parser --

  defp parse_call_activity(base, data) do
    process_name = case Map.get(data, "processName") do
      %{"name" => name} -> name
      name when is_binary(name) -> name
      _ -> nil
    end

    %Nodes.CallActivity{
      id: base.id, key: base.key,
      process_name: process_name,
      keep_business_key: Map.get(data, "keepBusinessKey", false),
      as_async_call: Map.get(data, "asAsyncCall", false),
      sequential_loop: Map.get(data, "sequentialLoop", false),
      collection_name: Map.get(data, "collectionName"),
      element_name: Map.get(data, "elementName"),
      result_variable: Map.get(data, "resultVariable"),
      boundary_events: Map.get(data, "boundaryEvents", []),
      properties: base.properties
    }
  end

  # -- Intermediate catch event parsers --

  defp parse_intermediate_catch(type, base, data)
       when type in ~w(intermediateTimerEvent intermediateCatchTimerEvent) do
    %Nodes.IntermediateCatch.TimerEvent{
      id: base.id, key: base.key,
      timer_config: parse_timer(data),
      properties: base.properties
    }
  end

  defp parse_intermediate_catch("intermediateCatchMessageEvent", base, data) do
    %Nodes.IntermediateCatch.MessageEvent{
      id: base.id, key: base.key,
      message: parse_message(data),
      properties: base.properties
    }
  end

  defp parse_intermediate_catch("intermediateCatchSignalEvent", base, data) do
    %Nodes.IntermediateCatch.SignalEvent{
      id: base.id, key: base.key,
      signal: Map.get(data, "signal"),
      properties: base.properties
    }
  end

  # -- Intermediate throw event parsers --

  defp parse_intermediate_throw("intermediateThrowMessageEvent", base, data) do
    %Nodes.IntermediateThrow.MessageEvent{
      id: base.id, key: base.key,
      message: parse_message(data),
      properties: base.properties
    }
  end

  defp parse_intermediate_throw("intermediateThrowSignalEvent", base, data) do
    %Nodes.IntermediateThrow.SignalEvent{
      id: base.id, key: base.key,
      signal: Map.get(data, "signal"),
      properties: base.properties
    }
  end

  defp parse_intermediate_throw("intermediateThrowErrorEvent", base, data) do
    %Nodes.IntermediateThrow.ErrorEvent{
      id: base.id, key: base.key,
      error_message: Map.get(data, "errorMessage") || Map.get(data, "message"),
      error_object: Map.get(data, "errorObject") || Map.get(data, "error"),
      properties: base.properties
    }
  end

  defp parse_intermediate_throw("intermediateThrowEscalationEvent", base, data) do
    %Nodes.IntermediateThrow.EscalationEvent{
      id: base.id, key: base.key,
      escalation: Map.get(data, "escalation"),
      properties: base.properties
    }
  end

  # -- Boundary event parsers --

  defp parse_boundary_event("timerBoundaryEvent", base, data) do
    %Nodes.BoundaryEvents.TimerBoundary{
      id: base.id, key: base.key,
      timer_config: parse_timer(data),
      attached_to: Map.get(data, "activity"),
      properties: base.properties
    }
  end

  defp parse_boundary_event("messageBoundaryEvent", base, data) do
    %Nodes.BoundaryEvents.MessageBoundary{
      id: base.id, key: base.key,
      message: parse_message(data),
      attached_to: Map.get(data, "activity"),
      properties: base.properties
    }
  end

  defp parse_boundary_event("signalBoundaryEvent", base, data) do
    %Nodes.BoundaryEvents.SignalBoundary{
      id: base.id, key: base.key,
      signal: Map.get(data, "signal"),
      attached_to: Map.get(data, "activity"),
      properties: base.properties
    }
  end

  defp parse_boundary_event("errorBoundaryEvent", base, data) do
    %Nodes.BoundaryEvents.ErrorBoundary{
      id: base.id, key: base.key,
      attached_to: Map.get(data, "activity"),
      properties: base.properties
    }
  end

  defp parse_boundary_event("escalationBoundaryEvent", base, data) do
    %Nodes.BoundaryEvents.EscalationBoundary{
      id: base.id, key: base.key,
      escalation: Map.get(data, "escalation"),
      attached_to: Map.get(data, "activity"),
      properties: base.properties
    }
  end

  defp parse_boundary_event("nonInterruptingTimerBoundaryEvent", base, data) do
    %Nodes.BoundaryEvents.NonInterruptingTimerBoundary{
      id: base.id, key: base.key,
      timer_config: parse_timer(data),
      attached_to: Map.get(data, "activity"),
      properties: base.properties
    }
  end

  defp parse_boundary_event("nonInterruptingMessageBoundaryEvent", base, data) do
    %Nodes.BoundaryEvents.NonInterruptingMessageBoundary{
      id: base.id, key: base.key,
      message: parse_message(data),
      attached_to: Map.get(data, "activity"),
      properties: base.properties
    }
  end

  defp parse_boundary_event("nonInterruptingSignalBoundaryEvent", base, data) do
    %Nodes.BoundaryEvents.NonInterruptingSignalBoundary{
      id: base.id, key: base.key,
      signal: Map.get(data, "signal"),
      attached_to: Map.get(data, "activity"),
      properties: base.properties
    }
  end

  # -- Connection parsing --

  defp parse_connections(conns) do
    Enum.reduce(conns, %{}, fn conn, acc ->
      from = Map.get(conn, "from")
      to = Map.get(conn, "to")
      Map.update(acc, from, [to], &[to | &1])
    end)
  end

  defp build_reverse_connections(connections) do
    Enum.reduce(connections, %{}, fn {from, tos}, acc ->
      Enum.reduce(tos, acc, fn to, acc2 ->
        Map.update(acc2, to, [from], &[from | &1])
      end)
    end)
  end

  defp parse_recursive_connections(conns) when is_list(conns) do
    Enum.reduce(conns, MapSet.new(), fn conn, acc ->
      from = Map.get(conn, "from")
      to = Map.get(conn, "to")
      if from && to, do: MapSet.put(acc, {from, to}), else: acc
    end)
  end
  defp parse_recursive_connections(_), do: MapSet.new()

  # -- Discovery functions --

  defp find_start_events(nodes) do
    nodes
    |> Enum.filter(fn {_id, node} ->
      match?(%Nodes.StartEvents.BlankStartEvent{}, node) ||
      match?(%Nodes.StartEvents.MessageStartEvent{}, node) ||
      match?(%Nodes.StartEvents.SignalStartEvent{}, node) ||
      match?(%Nodes.StartEvents.TimerStartEvent{}, node)
    end)
    |> Enum.map(fn {id, _} -> id end)
  end

  defp find_merging_gateways(nodes) do
    nodes
    |> Enum.filter(fn {_id, node} ->
      match?(%Nodes.Gateway{is_merging: true}, node)
    end)
    |> Enum.map(fn {id, _} -> id end)
  end

  # -- Property parsers --

  defp parse_start_kind(data, original_type) do
    case Map.get(data, "kind") do
      "ui" -> :ui
      "api" -> :api
      _ ->
        case original_type do
          "ApiStartEvent" -> :api
          "UiStartEvent" -> :ui
          _ -> :unspecified
        end
    end
  end

  defp parse_timer(data) do
    timer = Map.get(data, "timer", %{})
    case timer do
      duration when is_binary(duration) ->
        %{duration_ms: parse_iso_duration(duration)}

      timer_map when is_map(timer_map) ->
        %{
          cron_expression: Map.get(timer_map, "cronExpression"),
          duration_ms: Map.get(timer_map, "durationMs"),
          period: Map.get(timer_map, "period"),
          interval_ms: Map.get(timer_map, "intervalMs"),
          repetition_count: Map.get(timer_map, "repetitionCount")
        }

      _ -> %{}
    end
  end

  defp parse_iso_duration("PT" <> rest) do
    cond do
      String.ends_with?(rest, "s") || String.ends_with?(rest, "S") ->
        {val, _} = rest |> String.slice(0..-2//1) |> Float.parse()
        round(val * 1000)

      String.ends_with?(rest, "m") || String.ends_with?(rest, "M") ->
        {val, _} = rest |> String.slice(0..-2//1) |> Float.parse()
        round(val * 60_000)

      String.ends_with?(rest, "h") || String.ends_with?(rest, "H") ->
        {val, _} = rest |> String.slice(0..-2//1) |> Float.parse()
        round(val * 3_600_000)

      true -> 1000
    end
  end
  defp parse_iso_duration(_), do: 1000

  defp parse_message(data) do
    msg = Map.get(data, "message", %{})
    case msg do
      msg when is_map(msg) ->
        %{
          name: Map.get(msg, "name") || Map.get(msg, "staticText"),
          static_text: Map.get(msg, "staticText"),
          variable_name: Map.get(msg, "variableName"),
          variable_content: Map.get(msg, "variableContent"),
          payload_variable_name: Map.get(msg, "payloadVariableName")
        }

      name when is_binary(name) ->
        %{name: name, static_text: name, variable_name: nil, variable_content: nil, payload_variable_name: nil}

      _ ->
        %{name: nil, static_text: nil, variable_name: nil, variable_content: nil, payload_variable_name: nil}
    end
  end

  defp parse_expressions(data) do
    expressions = Map.get(data, "expressions", %{})
    expression_mapping = Map.get(data, "expressionMapping")

    if expression_mapping && map_size(expression_mapping) > 0 do
      # .NET format: expressionMapping maps node IDs to expression names,
      # expressions maps expression names to expression strings
      Enum.into(expression_mapping, %{}, fn {node_id_str, expr_name} ->
        node_id = if is_binary(node_id_str), do: String.to_integer(node_id_str), else: node_id_str
        expression = Map.get(expressions, expr_name, "")
        {node_id, expression}
      end)
    else
      # Direct format: node_id -> expression
      Enum.into(expressions, %{}, fn {k, v} ->
        key = if is_binary(k), do: String.to_integer(k), else: k
        {key, v}
      end)
    end
  end

  defp parse_error_behaviour(data) do
    case Map.get(data, "errorBehaviour") do
      "retry" -> :retry
      "ignore" -> :ignore
      _ -> :fail
    end
  end

  # -- Extension extraction --

  defp extract_extension_properties(data) do
    extensions = Map.get(data, "extensions", [])

    ext =
      Enum.find(extensions, fn e ->
        name = Map.get(e, "name", "")
        name == "PSS.RestTask" or name == "PSS.UserTask"
      end)

    case ext do
      %{"data" => ext_data} when is_map(ext_data) -> ext_data
      _ -> %{}
    end
  end
end
