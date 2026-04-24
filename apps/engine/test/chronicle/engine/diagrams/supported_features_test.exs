defmodule Chronicle.Engine.Diagrams.SupportedFeaturesTest do
  use ExUnit.Case, async: true

  alias Chronicle.Engine.Diagrams.{Parser, SupportedFeatures}
  alias Chronicle.Engine.Nodes

  test "manifest exposes supported and unsupported node types" do
    assert "externalTask" in SupportedFeatures.supported_node_types()
    assert "eventBasedGateway" in SupportedFeatures.unsupported_node_types()
    assert SupportedFeatures.unsupported_reason("eventBasedGateway") =~ "not implemented"
  end

  test "parser rejects unsupported BPMN features instead of falling through" do
    bpjs = %{
      "name" => "unsupported",
      "version" => 1,
      "nodes" => [
        %{"id" => 1, "type" => "blankStartEvent"},
        %{"id" => 2, "type" => "eventBasedGateway"}
      ],
      "connections" => [%{"from" => 1, "to" => 2}]
    }

    assert {:error, {:unsupported_node_type, "eventBasedGateway", reason}} =
             Parser.parse(Jason.encode!(bpjs))

    assert reason =~ "Event-based gateways"
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
end
