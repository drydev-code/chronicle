defmodule Chronicle.Engine.Diagrams.Parser do
  @moduledoc """
  Parse JSON/BPJS diagram format into ProcessDefinition.
  Supports both PascalCase (.NET) and camelCase JSON formats.
  """
  alias Chronicle.Engine.Diagrams.Definition
  alias Chronicle.Engine.Diagrams.SupportedFeatures
  alias Chronicle.Engine.Nodes

  def parse(json_string) when is_binary(json_string) do
    json_string = String.trim_leading(json_string, "\uFEFF")

    case Jason.decode(json_string) do
      {:ok, data} -> parse_definition(data)
      {:error, reason} -> {:error, {:parse_error, reason}}
    end
  end

  def parse_definition(data) when is_map(data) do
    try do
      do_parse_definition(data)
    catch
      {:duplicate_node_ids, ids} -> {:error, {:duplicate_node_ids, ids}}
      {:unsupported_node_type, type, reason} -> {:error, {:unsupported_node_type, type, reason}}
      {:invalid_event_based_gateway_branch, gateway_id, branch_id, branch_type} ->
        {:error, {:invalid_event_based_gateway_branch, gateway_id, branch_id, branch_type}}
    end
  end

  defp do_parse_definition(data) do
    data = normalize_keys(data)
    reject_collaboration_shapes!(data)
    resources = Map.get(data, "resources", %{})
    processes = Map.get(data, "processes", [data])

    definitions = Enum.map(processes, fn process ->
      reject_collaboration_shapes!(process)
      nodes_data = Map.get(process, "nodes", [])
      validate_unique_node_ids!(nodes_data)

      {lanes, node_lanes} = parse_lanes(Map.get(process, "lanes", []))
      nodes = parse_nodes(nodes_data, lanes, node_lanes, resources)
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

      nodes_with_outputs = attach_boundary_events(nodes_with_outputs)
      validate_event_based_gateways!(nodes_with_outputs)

      %Definition{
        name: Map.get(process, "name", "unknown"),
        version: Map.get(process, "version") || Map.get(data, "version"),
        tenant: Map.get(process, "tenant") || Map.get(data, "tenant"),
        nodes: nodes_with_outputs,
        connections: connections,
        reverse_connections: reverse_connections,
        lanes: lanes,
        node_lanes: node_lanes,
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

  # Collect raw node IDs before map conversion (which silently drops duplicates)
  # and throw if any duplicates exist; caller converts throw to {:error, ...}.
  # Checks both string ("id" / "Id") and atom (:id) key variants because
  # this runs after normalize_keys has already lowercased top-level keys.
  defp validate_unique_node_ids!(nodes_data) when is_list(nodes_data) do
    raw_ids =
      Enum.map(nodes_data, fn
        n when is_map(n) ->
          Map.get(n, "id") || Map.get(n, :id) || Map.get(n, "Id")

        _ ->
          nil
      end)

    duplicates = raw_ids -- Enum.uniq(raw_ids)

    case duplicates do
      [] -> :ok
      ids -> throw({:duplicate_node_ids, Enum.uniq(ids)})
    end
  end

  defp validate_unique_node_ids!(_), do: :ok

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
  defp normalize_type("ServiceTaskREST"), do: "externalTask"
  defp normalize_type("ServiceTaskLLM"), do: "externalTask"
  defp normalize_type("ServiceTaskEmail"), do: "externalTask"
  defp normalize_type("ServiceTaskDB"), do: "externalTask"
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

  defp parse_nodes(nodes_data, lanes, node_lanes, resources) do
    Enum.into(nodes_data, %{}, fn node_data ->
      id = Map.get(node_data, "id")
      node = parse_node(node_data, resources)
      node = apply_lane_actor_type(node, Map.get(lanes, Map.get(node_lanes, id)))
      {id, node}
    end)
  end

  defp parse_lanes(lanes) when is_list(lanes) do
    Enum.reduce(lanes, {%{}, %{}}, fn lane_data, {lanes_acc, node_lanes_acc} ->
      lane_id = Map.get(lane_data, "id") || Map.get(lane_data, "key") || Map.get(lane_data, "name")
      properties = Map.get(lane_data, "properties") || extract_extension_properties(lane_data)
      actor_type = Map.get(lane_data, "actorType") || Map.get(properties || %{}, "actorType")

      lane = %{
        id: lane_id,
        key: Map.get(lane_data, "key"),
        name: Map.get(lane_data, "name"),
        actor_type: actor_type,
        properties: properties || %{}
      }

      node_ids =
        ["nodes", "nodeIds", "flowNodeRefs", "flowNodes"]
        |> Enum.flat_map(fn key -> List.wrap(Map.get(lane_data, key, [])) end)
        |> Enum.map(&normalize_lane_node_ref/1)
        |> Enum.reject(&is_nil/1)

      lanes_acc = if lane_id, do: Map.put(lanes_acc, lane_id, lane), else: lanes_acc

      node_lanes_acc =
        Enum.reduce(node_ids, node_lanes_acc, fn node_id, acc ->
          if lane_id, do: Map.put(acc, node_id, lane_id), else: acc
        end)

      {lanes_acc, node_lanes_acc}
    end)
  end

  defp parse_lanes(_), do: {%{}, %{}}

  defp normalize_lane_node_ref(%{"id" => id}), do: id
  defp normalize_lane_node_ref(%{"nodeId" => id}), do: id
  defp normalize_lane_node_ref(%{"flowNodeRef" => id}), do: id
  defp normalize_lane_node_ref(id) when is_integer(id) or is_binary(id), do: id
  defp normalize_lane_node_ref(_), do: nil

  defp apply_lane_actor_type(node, %{actor_type: actor_type} = lane)
       when actor_type not in [nil, ""] and is_map_key(node, :properties) do
    properties = Map.get(node, :properties) || %{}

    properties =
      properties
      |> Map.put_new("actorType", actor_type)
      |> Map.put("lane", Map.take(lane, [:id, :key, :name, :actor_type]))

    %{node | properties: properties}
  end

  defp apply_lane_actor_type(node, _lane), do: node

  defp parse_node(%{"type" => original_type} = data, resources) do
    ensure_supported_original_type!(original_type)
    type = normalize_type(original_type)
    ensure_supported_node_type!(type)

    id = Map.get(data, "id")
    key = Map.get(data, "key")
    properties = build_properties(data, original_type)
    properties = maybe_put_loop_characteristics(properties, data)
    base = %{id: id, key: key, properties: properties, resources: resources, original_type: original_type}

    case type do
      t when t in ~w(blankStartEvent messageStartEvent signalStartEvent timerStartEvent conditionalStartEvent) ->
        parse_start_event(t, base, data, original_type)

      t when t in ~w(blankEndEvent errorEndEvent messageEndEvent signalEndEvent escalationEndEvent terminationEndEvent compensationEndEvent) ->
        parse_end_event(t, base, data)

      t when t in ~w(scriptTask externalTask userTask rulesTask manualTask sendTask receiveTask) ->
        parse_task_node(t, base, data)

      t when t in ~w(parallelGateway exclusiveGateway inclusiveGateway eventBasedGateway) ->
        parse_gateway_node(t, base, data)

      t when t in ~w(intermediateTimerEvent intermediateCatchTimerEvent intermediateCatchMessageEvent intermediateCatchSignalEvent intermediateCatchConditionalEvent intermediateCatchLinkEvent) ->
        parse_intermediate_catch(t, base, data)

      t when t in ~w(intermediateThrowMessageEvent intermediateThrowSignalEvent intermediateThrowErrorEvent intermediateThrowEscalationEvent intermediateThrowLinkEvent intermediateThrowCompensationEvent) ->
        parse_intermediate_throw(t, base, data)

      t when t in ~w(timerBoundaryEvent messageBoundaryEvent signalBoundaryEvent conditionalBoundaryEvent compensationBoundaryEvent errorBoundaryEvent escalationBoundaryEvent nonInterruptingTimerBoundaryEvent nonInterruptingMessageBoundaryEvent nonInterruptingSignalBoundaryEvent nonInterruptingConditionalBoundaryEvent) ->
        parse_boundary_event(t, base, data)

      "callActivity" ->
        parse_call_activity(base, data)

      _ ->
        throw({:unsupported_node_type, type, "Node type is not in the Chronicle BPJS executable subset."})
    end
  end

  defp ensure_supported_original_type!(type) do
    normalized = to_camel_case(type)

    if reason = SupportedFeatures.unsupported_reason(normalized) do
      throw({:unsupported_node_type, type, reason})
    else
      :ok
    end
  end

  defp ensure_supported_node_type!(type) do
    cond do
      SupportedFeatures.supported?(type) ->
        :ok

      reason = SupportedFeatures.unsupported_reason(type) ->
        throw({:unsupported_node_type, type, reason})

      true ->
        throw({:unsupported_node_type, type, "Node type is not in the Chronicle BPJS executable subset."})
    end
  end

  defp reject_collaboration_shapes!(data) do
    unsupported =
      [
        {"collaborations", "BPMN collaborations are not implemented."},
        {"participants", "BPMN participants/pools are not implemented."},
        {"pools", "BPMN pools are not implemented."},
        {"messageFlows", "BPMN message flows are not implemented."}
      ]

    Enum.each(unsupported, fn {key, reason} ->
      case Map.get(data, key) do
        nil -> :ok
        [] -> :ok
        _ -> throw({:unsupported_node_type, key, reason})
      end
    end)
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

  defp parse_start_event("conditionalStartEvent", base, data, _original_type) do
    condition = Map.get(data, "condition") || Map.get(base.properties, "condition")

    if condition in [nil, ""] do
      throw({:unsupported_node_type, "conditionalStartEvent", "Conditional start events require a condition expression."})
    end

    %Nodes.StartEvents.ConditionalStartEvent{
      id: base.id, key: base.key,
      condition: condition,
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

  defp parse_end_event("compensationEndEvent", base, _data) do
    %Nodes.EndEvents.CompensationEndEvent{
      id: base.id, key: base.key,
      properties: base.properties
    }
  end

  # -- Task node parsers --

  defp parse_task_node("scriptTask", base, data) do
    %Nodes.ScriptTask{
      id: base.id, key: base.key,
      script: build_script(data, base.resources),
      boundary_events: Map.get(data, "boundaryEvents", []),
      properties: base.properties
    }
  end

  defp parse_task_node("externalTask", base, data) do
    kind = case Map.get(data, "kind") do
      "user" -> :user
      "service" -> :service
      _ ->
        if base.original_type == "UserTask", do: :user, else: :service
    end

    %Nodes.ExternalTask{
      id: base.id, key: base.key, kind: kind,
      result_variable: external_task_result_variable(data, base.properties),
      error_behaviour: parse_error_behaviour(data),
      boundary_events: Map.get(data, "boundaryEvents", []),
      properties: base.properties
    }
  end

  defp parse_task_node("userTask", base, data) do
    %Nodes.ExternalTask{
      id: base.id, key: base.key, kind: :user,
      result_variable: external_task_result_variable(data, base.properties),
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

  defp parse_task_node("manualTask", base, _data) do
    %Nodes.Tasks.ManualTask{
      id: base.id, key: base.key,
      boundary_events: [],
      properties: base.properties
    }
  end

  defp parse_task_node("sendTask", base, data) do
    %Nodes.Tasks.SendTask{
      id: base.id, key: base.key,
      message: parse_message(data),
      boundary_events: Map.get(data, "boundaryEvents", []),
      properties: base.properties
    }
  end

  defp parse_task_node("receiveTask", base, data) do
    %Nodes.Tasks.ReceiveTask{
      id: base.id, key: base.key,
      message: parse_message(data),
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

  defp parse_gateway_node("eventBasedGateway", base, _data) do
    %Nodes.Gateway{
      id: base.id, key: base.key, kind: :event_based,
      is_merging: false,
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
      as_async_call: if(base.original_type == "SubProcess", do: false, else: Map.get(data, "asAsyncCall", false)),
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

  defp parse_intermediate_catch("intermediateCatchConditionalEvent", base, data) do
    %Nodes.IntermediateCatch.ConditionalEvent{
      id: base.id, key: base.key,
      condition: Map.get(data, "condition") || Map.get(base.properties, "condition"),
      properties: base.properties
    }
  end

  defp parse_intermediate_catch("intermediateCatchLinkEvent", base, data) do
    %Nodes.IntermediateCatch.LinkEvent{
      id: base.id, key: base.key,
      link_name: Map.get(data, "linkName") || Map.get(data, "name") || Map.get(base.properties, "linkName"),
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

  defp parse_intermediate_throw("intermediateThrowLinkEvent", base, data) do
    %Nodes.IntermediateThrow.LinkEvent{
      id: base.id, key: base.key,
      link_name: Map.get(data, "linkName") || Map.get(data, "name") || Map.get(base.properties, "linkName"),
      properties: base.properties
    }
  end

  defp parse_intermediate_throw("intermediateThrowCompensationEvent", base, _data) do
    %Nodes.IntermediateThrow.CompensationEvent{
      id: base.id, key: base.key,
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

  defp parse_boundary_event("conditionalBoundaryEvent", base, data) do
    condition = Map.get(data, "condition") || Map.get(base.properties, "condition")

    if condition in [nil, ""] do
      throw({:unsupported_node_type, "conditionalBoundaryEvent", "Conditional boundary events require a condition expression."})
    end

    %Nodes.BoundaryEvents.ConditionalBoundary{
      id: base.id, key: base.key,
      condition: condition,
      attached_to: Map.get(data, "activity"),
      properties: base.properties
    }
  end

  defp parse_boundary_event("compensationBoundaryEvent", base, data) do
    %Nodes.BoundaryEvents.CompensationBoundary{
      id: base.id, key: base.key,
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

  defp parse_boundary_event("nonInterruptingConditionalBoundaryEvent", base, data) do
    condition = Map.get(data, "condition") || Map.get(base.properties, "condition")

    if condition in [nil, ""] do
      throw({:unsupported_node_type, "nonInterruptingConditionalBoundaryEvent", "Non-interrupting conditional boundary events require a condition expression."})
    end

    %Nodes.BoundaryEvents.NonInterruptingConditionalBoundary{
      id: base.id, key: base.key,
      condition: condition,
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
      match?(%Nodes.StartEvents.TimerStartEvent{}, node) ||
      match?(%Nodes.StartEvents.ConditionalStartEvent{}, node)
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

  defp attach_boundary_events(nodes) do
    boundaries =
      nodes
      |> Map.values()
      |> Enum.filter(&boundary_event?/1)
      |> Enum.group_by(&Map.get(&1, :attached_to))

    Enum.into(nodes, %{}, fn {id, node} ->
      node =
        case Map.get(boundaries, id) do
          nil -> node
          attached -> if Map.has_key?(node, :boundary_events), do: %{node | boundary_events: attached}, else: node
        end

      {id, node}
    end)
  end

  defp validate_event_based_gateways!(nodes) do
    Enum.each(nodes, fn
      {gateway_id, %Nodes.Gateway{kind: :event_based, outputs: outputs}} ->
        Enum.each(outputs || [], fn branch_id ->
          branch = Map.get(nodes, branch_id)

          unless event_based_gateway_branch?(branch) do
            type = branch && (branch.__struct__ |> Module.split() |> List.last())
            throw({:invalid_event_based_gateway_branch, gateway_id, branch_id, type})
          end
        end)

      _ ->
        :ok
    end)
  end

  defp event_based_gateway_branch?(%Nodes.IntermediateCatch.MessageEvent{}), do: true
  defp event_based_gateway_branch?(%Nodes.Tasks.ReceiveTask{}), do: true
  defp event_based_gateway_branch?(%Nodes.IntermediateCatch.SignalEvent{}), do: true
  defp event_based_gateway_branch?(%Nodes.IntermediateCatch.TimerEvent{}), do: true
  defp event_based_gateway_branch?(_), do: false

  defp boundary_event?(%Nodes.BoundaryEvents.TimerBoundary{}), do: true
  defp boundary_event?(%Nodes.BoundaryEvents.MessageBoundary{}), do: true
  defp boundary_event?(%Nodes.BoundaryEvents.SignalBoundary{}), do: true
  defp boundary_event?(%Nodes.BoundaryEvents.ErrorBoundary{}), do: true
  defp boundary_event?(%Nodes.BoundaryEvents.EscalationBoundary{}), do: true
  defp boundary_event?(%Nodes.BoundaryEvents.ConditionalBoundary{}), do: true
  defp boundary_event?(%Nodes.BoundaryEvents.CompensationBoundary{}), do: true
  defp boundary_event?(%Nodes.BoundaryEvents.NonInterruptingTimerBoundary{}), do: true
  defp boundary_event?(%Nodes.BoundaryEvents.NonInterruptingMessageBoundary{}), do: true
  defp boundary_event?(%Nodes.BoundaryEvents.NonInterruptingSignalBoundary{}), do: true
  defp boundary_event?(%Nodes.BoundaryEvents.NonInterruptingConditionalBoundary{}), do: true
  defp boundary_event?(_), do: false

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
      2 -> :retry
      1 -> :ignore
      _ -> :fail
    end
  end

  defp maybe_put_loop_characteristics(properties, data) do
    loop =
      Map.get(data, "standardLoop") ||
        Map.get(data, "loopCharacteristics") ||
        Map.get(data, "loop")

    parsed = parse_loop_characteristics(loop || Map.get(properties || %{}, "loopCharacteristics"))

    if parsed do
      Map.put(properties || %{}, "loopCharacteristics", parsed)
    else
      properties || %{}
    end
  end

  defp parse_loop_characteristics(loop) when is_map(loop) do
    condition =
      Map.get(loop, "condition") ||
        Map.get(loop, "loopCondition") ||
        Map.get(loop, "expression")

    max_iterations =
      Map.get(loop, "maxIterations") ||
        Map.get(loop, "maximum") ||
        Map.get(loop, "max")

    cond do
      Map.get(loop, "isSequential") == true or Map.get(loop, "multiInstance") == true ->
        throw({:unsupported_node_type, "loopCharacteristics", "Multi-instance activity characteristics are not implemented."})

      condition in [nil, ""] and max_iterations in [nil, ""] ->
        nil

      true ->
        %{
          "condition" => condition,
          "maxIterations" => parse_optional_int(max_iterations),
          "testBefore" => Map.get(loop, "testBefore", false)
        }
    end
  end

  defp parse_loop_characteristics(_), do: nil

  defp parse_optional_int(nil), do: nil
  defp parse_optional_int(""), do: nil
  defp parse_optional_int(value) when is_integer(value), do: value
  defp parse_optional_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> nil
    end
  end
  defp parse_optional_int(_), do: nil

  # -- Extension extraction --

  defp build_properties(data, original_type) do
    data
    |> Map.get("properties", %{})
    |> merge_properties(extract_extension_properties(data))
    |> merge_properties(specialized_task_properties(original_type, data))
  end

  defp merge_properties(nil, right), do: right || %{}
  defp merge_properties(left, nil), do: left || %{}
  defp merge_properties(left, right) when is_map(left) and is_map(right), do: deep_merge_properties(left, right)
  defp merge_properties(_left, right), do: right || %{}

  defp deep_merge_properties(left, right) do
    Map.merge(left, right, fn
      "extensions", left_ext, right_ext when is_map(left_ext) and is_map(right_ext) ->
        Map.merge(left_ext, right_ext)

      _key, _left_value, right_value ->
        right_value
    end)
  end

  defp extract_extension_properties(data) do
    extension_candidates(data)
    |> Enum.reduce(%{}, fn extension, acc ->
      case extension_properties(extension) do
        props when is_map(props) -> Map.merge(acc, props)
        _ -> acc
      end
    end)
  end

  defp extension_candidates(data) do
    List.wrap(Map.get(data, "extensions", [])) ++ List.wrap(Map.get(data, "extension"))
  end

  defp extension_properties(%{"key" => "__EditorData"}), do: %{}
  defp extension_properties(%{"name" => name} = extension), do: named_extension_properties(name, extension)
  defp extension_properties(%{"key" => key} = extension), do: named_extension_properties(key, extension)
  defp extension_properties(%{"type" => type} = extension), do: named_extension_properties(type, extension)
  defp extension_properties(extension) when is_map(extension), do: Map.get(extension, "data") || %{}
  defp extension_properties(_), do: %{}

  defp named_extension_properties(name, extension) do
    name = normalize_extension_name(name)
    data = Map.get(extension, "data") || Map.get(extension, "value") || %{}
    data = decode_extension_data(data)

    case name do
      name when name in ["resttask", "servicetaskrest"] -> rest_properties(data)
      name when name in ["llmtask", "aitask", "servicetaskllm"] -> ai_properties(data)
      name when name in ["dbtask", "databasetask", "servicetaskdb"] -> db_properties(data)
      name when name in ["emailtask", "servicetaskemail"] -> email_properties(data)
      name when name in ["usertask"] -> user_task_properties(data)
      _ -> %{}
    end
  end

  defp normalize_extension_name(name) when is_binary(name) do
    name
    |> String.trim()
    |> String.replace_prefix("Chronicle.", "")
    |> String.downcase()
  end
  defp normalize_extension_name(name), do: to_string(name) |> normalize_extension_name()

  defp decode_extension_data(data) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, decoded} -> normalize_keys(decoded)
      {:error, _} -> %{"value" => data}
    end
  end
  defp decode_extension_data(data) when is_map(data), do: normalize_keys(data)
  defp decode_extension_data(data), do: data

  defp specialized_task_properties(type, data) when type in ["ServiceTaskREST", "ServiceTaskLLM", "ServiceTaskEmail", "ServiceTaskDB"] do
    properties = Map.get(data, "properties", %{})

    case type do
      "ServiceTaskREST" -> rest_properties(properties)
      "ServiceTaskLLM" -> ai_properties(properties)
      "ServiceTaskEmail" -> email_properties(properties)
      "ServiceTaskDB" -> db_properties(properties)
    end
  end
  defp specialized_task_properties("UserTask", data), do: user_task_properties(Map.get(data, "properties", %{}))
  defp specialized_task_properties(_type, _data), do: %{}

  defp rest_properties(data) do
    %{
      "topic" => "rest",
      "endpoint" => Map.get(data, "endpoint") || Map.get(data, "endPoint"),
      "method" => Map.get(data, "method"),
      "body" => Map.get(data, "body") || Map.get(data, "requestBody"),
      "extensions" => compact_map(%{
        "headers" => Map.get(data, "headers"),
        "bearerToken" => Map.get(data, "bearerToken"),
        "apiKey" => Map.get(data, "apiKey"),
        "resultMode" => Map.get(data, "resultMode") || "body",
        "resultPath" => Map.get(data, "resultPath")
      })
    }
    |> compact_map()
  end

  defp ai_properties(data) do
    %{
      "topic" => "ai",
      "endpoint" => Map.get(data, "endpoint"),
      "resultVariable" => Map.get(data, "resultVariable") || Map.get(data, "outputVariable"),
      "extensions" => compact_map(%{
        "model" => Map.get(data, "model"),
        "prompt" => Map.get(data, "prompt") || Map.get(data, "userPrompt"),
        "systemPrompt" => Map.get(data, "systemPrompt"),
        "resultMode" => Map.get(data, "resultMode") || "body",
        "resultPath" => Map.get(data, "resultPath")
      })
    }
    |> compact_map()
  end

  defp db_properties(data) do
    %{
      "topic" => "database",
      "resultVariable" => Map.get(data, "resultVariable"),
      "extensions" => compact_map(%{
        "connectionId" => Map.get(data, "connectionId"),
        "queryType" => Map.get(data, "queryType"),
        "query" => Map.get(data, "query"),
        "params" => Map.get(data, "params") || Map.get(data, "parameters"),
        "resultMode" => Map.get(data, "resultMode") || "result"
      })
    }
    |> compact_map()
  end

  defp email_properties(data) do
    %{
      "topic" => "email",
      "extensions" => compact_map(Map.take(data, ["fromEmail", "to", "cc", "bcc", "subject", "body", "isHtml", "attachments"]))
    }
    |> compact_map()
  end

  defp user_task_properties(data) do
    %{
      "view" => Map.get(data, "view"),
      "assignments" => Map.get(data, "assignments"),
      "subject" => Map.get(data, "subject") || Map.get(data, "formTitle"),
      "configuration" => Map.get(data, "configuration") || Map.get(data, "formSchema"),
      "actorType" => Map.get(data, "actorType")
    }
    |> compact_map()
  end

  defp compact_map(map) do
    map
    |> Enum.reject(fn {_k, v} -> v in [nil, "", %{}, []] end)
    |> Map.new()
  end

  defp external_task_result_variable(data, properties) do
    Map.get(data, "resultVariable") ||
      Map.get(properties || %{}, "resultVariable") ||
      Map.get(properties || %{}, "outputVariable")
  end

  defp build_script(data, resources) do
    input_scripts = script_refs_to_source(Map.get(data, "inputScripts", []), resources)
    main_script = script_ref_to_source(Map.get(data, "script"), resources)
    output_scripts = script_refs_to_source(Map.get(data, "outputScripts", []), resources)

    keep_all =
      if Map.get(data, "exportAllToTokenContext") do
        ["KeepAll();"]
      else
        []
      end

    (keep_all ++ input_scripts ++ List.wrap(main_script) ++ output_scripts)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
  end

  defp script_refs_to_source(refs, resources) when is_list(refs) do
    Enum.map(refs, &script_ref_to_source(&1, resources))
  end
  defp script_refs_to_source(_refs, _resources), do: []

  defp script_ref_to_source(nil, _resources), do: nil
  defp script_ref_to_source(script, _resources) when is_binary(script), do: script
  defp script_ref_to_source(ref, resources) do
    resource = Map.get(resources, to_string(ref)) || Map.get(resources, ref)
    resource_to_script(resource)
  end

  defp resource_to_script(nil), do: nil
  defp resource_to_script(%{"source" => source, "returnVariable" => return_variable}) when is_binary(return_variable) and return_variable != "" do
    source = String.trim_trailing(String.trim(source), ";")
    "Set(\"#{return_variable}\", (#{source}));"
  end
  defp resource_to_script(%{"source" => source}) when is_binary(source), do: source
  defp resource_to_script(%{"data" => data, "isBase64Data" => true}) when is_binary(data) do
    case Base.decode64(data) do
      {:ok, decoded} -> decoded
      :error -> nil
    end
  end
  defp resource_to_script(_), do: nil
end
