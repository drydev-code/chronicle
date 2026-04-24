defmodule Chronicle.Engine.Diagrams.SupportedFeaturesTest do
  use ExUnit.Case, async: true

  alias Chronicle.Engine.Diagrams.{Parser, SupportedFeatures}
  alias Chronicle.Engine.Nodes

  test "manifest exposes supported and unsupported node types" do
    assert "externalTask" in SupportedFeatures.supported_node_types()
    assert "eventBasedGateway" in SupportedFeatures.supported_node_types()
    assert "sendTask" in SupportedFeatures.supported_node_types()
    assert "receiveTask" in SupportedFeatures.supported_node_types()
    assert "manualTask" in SupportedFeatures.supported_node_types()
    assert "intermediateCatchLinkEvent" in SupportedFeatures.supported_node_types()
    assert "intermediateThrowLinkEvent" in SupportedFeatures.supported_node_types()
    assert "conditionalStartEvent" in SupportedFeatures.supported_node_types()
    assert "transaction" in SupportedFeatures.unsupported_node_types()
    assert SupportedFeatures.unsupported_reason("transaction") =~ "not implemented"
  end

  test "parser accepts newly supported first-class BPJS BPMN nodes" do
    bpjs = %{
      "name" => "supported",
      "version" => 1,
      "nodes" => [
        %{"id" => 1, "type" => "blankStartEvent"},
        %{"id" => 2, "type" => "manualTask"},
        %{"id" => 3, "type" => "sendTask", "message" => "sent"},
        %{"id" => 4, "type" => "receiveTask", "message" => "received"},
        %{"id" => 5, "type" => "eventBasedGateway"},
        %{"id" => 6, "type" => "intermediateCatchMessageEvent", "message" => "approved"},
        %{"id" => 7, "type" => "intermediateThrowLinkEvent", "linkName" => "skip"},
        %{"id" => 8, "type" => "intermediateCatchLinkEvent", "linkName" => "skip"},
        %{"id" => 9, "type" => "blankEndEvent"}
      ],
      "connections" => [
        %{"from" => 1, "to" => 2},
        %{"from" => 2, "to" => 3},
        %{"from" => 3, "to" => 4},
        %{"from" => 4, "to" => 5},
        %{"from" => 5, "to" => 6},
        %{"from" => 6, "to" => 7},
        %{"from" => 7, "to" => 8},
        %{"from" => 8, "to" => 9}
      ]
    }

    assert {:ok, definition} = Parser.parse(Jason.encode!(bpjs))

    assert %Nodes.Tasks.ManualTask{} = definition.nodes[2]
    assert %Nodes.Tasks.SendTask{} = definition.nodes[3]
    assert %Nodes.Tasks.ReceiveTask{} = definition.nodes[4]
    assert %Nodes.Gateway{kind: :event_based} = definition.nodes[5]
    assert %Nodes.IntermediateThrow.LinkEvent{link_name: "skip"} = definition.nodes[7]
    assert %Nodes.IntermediateCatch.LinkEvent{link_name: "skip"} = definition.nodes[8]
  end

  test "parser still rejects unsupported BPMN features instead of falling through" do
    bpjs = %{
      "name" => "unsupported",
      "version" => 1,
      "nodes" => [
        %{"id" => 1, "type" => "blankStartEvent"},
        %{"id" => 2, "type" => "transaction"}
      ],
      "connections" => [%{"from" => 1, "to" => 2}]
    }

    assert {:error, {:unsupported_node_type, "transaction", reason}} =
             Parser.parse(Jason.encode!(bpjs))

    assert reason =~ "Transaction subprocess"
  end

  test "conditional start requires a condition expression" do
    bpjs = %{
      "name" => "bad-conditional-start",
      "version" => 1,
      "nodes" => [
        %{"id" => 1, "type" => "conditionalStartEvent"},
        %{"id" => 2, "type" => "blankEndEvent"}
      ],
      "connections" => [%{"from" => 1, "to" => 2}]
    }

    assert {:error, {:unsupported_node_type, "conditionalStartEvent", reason}} =
             Parser.parse(Jason.encode!(bpjs))

    assert reason =~ "require a condition"
  end

  test "parser rejects embedded SubProcess alias rather than treating it as callActivity" do
    bpjs = %{
      "name" => "unsupported-subprocess",
      "version" => 1,
      "nodes" => [
        %{"id" => 1, "type" => "blankStartEvent"},
        %{"id" => 2, "type" => "SubProcess"}
      ],
      "connections" => [%{"from" => 1, "to" => 2}]
    }

    assert {:error, {:unsupported_node_type, "SubProcess", reason}} =
             Parser.parse(Jason.encode!(bpjs))

    assert reason =~ "Embedded subprocess"
  end

  test "boundary nodes are attached to their target activity as parsed structs" do
    bpjs = %{
      "name" => "boundary-attach",
      "version" => 1,
      "nodes" => [
        %{"id" => 1, "type" => "blankStartEvent"},
        %{"id" => 2, "type" => "externalTask", "kind" => "service", "key" => "task"},
        %{"id" => 3, "type" => "timerBoundaryEvent", "activity" => 2, "timer" => %{"durationMs" => 100}},
        %{"id" => 4, "type" => "blankEndEvent"},
        %{"id" => 5, "type" => "blankEndEvent"}
      ],
      "connections" => [
        %{"from" => 1, "to" => 2},
        %{"from" => 2, "to" => 4},
        %{"from" => 3, "to" => 5}
      ]
    }

    assert {:ok, definition} = Parser.parse(Jason.encode!(bpjs))
    task = definition.nodes[2]

    assert [%Nodes.BoundaryEvents.TimerBoundary{id: 3, outputs: [5]}] = task.boundary_events
  end

  test "lanes resolve actorType metadata without overriding explicit node actorType" do
    bpjs = %{
      "name" => "lane-routing",
      "version" => 1,
      "lanes" => [
        %{
          "id" => "operations-lane",
          "name" => "Operations",
          "properties" => %{"actorType" => "OperationsActor"},
          "nodeIds" => [2, 3]
        }
      ],
      "nodes" => [
        %{"id" => 1, "type" => "blankStartEvent"},
        %{"id" => 2, "type" => "externalTask", "kind" => "service", "key" => "service"},
        %{
          "id" => 3,
          "type" => "userTask",
          "key" => "user",
          "properties" => %{"actorType" => "ExplicitActor"}
        },
        %{"id" => 4, "type" => "blankEndEvent"}
      ],
      "connections" => [
        %{"from" => 1, "to" => 2},
        %{"from" => 2, "to" => 3},
        %{"from" => 3, "to" => 4}
      ]
    }

    assert {:ok, definition} = Parser.parse(Jason.encode!(bpjs))

    assert definition.lanes["operations-lane"].actor_type == "OperationsActor"
    assert definition.node_lanes[2] == "operations-lane"
    assert definition.nodes[2].properties["actorType"] == "OperationsActor"
    assert definition.nodes[3].properties["actorType"] == "ExplicitActor"
    assert definition.nodes[2].properties["lane"].name == "Operations"
  end

  test "parser rejects collaboration shapes while allowing lane metadata" do
    bpjs = %{
      "name" => "collaboration",
      "version" => 1,
      "participants" => [%{"id" => "pool"}],
      "nodes" => [
        %{"id" => 1, "type" => "blankStartEvent"},
        %{"id" => 2, "type" => "blankEndEvent"}
      ],
      "connections" => [%{"from" => 1, "to" => 2}]
    }

    assert {:error, {:unsupported_node_type, "participants", reason}} =
             Parser.parse(Jason.encode!(bpjs))

    assert reason =~ "participants"
  end

  test "event-based gateway rejects unsupported outgoing branches during parsing" do
    bpjs = %{
      "name" => "bad-event-gateway",
      "version" => 1,
      "nodes" => [
        %{"id" => 1, "type" => "blankStartEvent"},
        %{"id" => 2, "type" => "eventBasedGateway"},
        %{"id" => 3, "type" => "scriptTask", "script" => "return {};"},
        %{"id" => 4, "type" => "blankEndEvent"}
      ],
      "connections" => [
        %{"from" => 1, "to" => 2},
        %{"from" => 2, "to" => 3},
        %{"from" => 3, "to" => 4}
      ]
    }

    assert {:error, {:invalid_event_based_gateway_branch, 2, 3, "ScriptTask"}} =
             Parser.parse(Jason.encode!(bpjs))
  end
end
