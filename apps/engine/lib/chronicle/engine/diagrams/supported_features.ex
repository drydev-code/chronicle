defmodule Chronicle.Engine.Diagrams.SupportedFeatures do
  @moduledoc """
  Manifest for the executable BPJS BPMN node subset supported by Chronicle.

  Native BPMN XML and full BPMN 2.0 conformance are intentionally out of
  scope for this release. Unsupported node types must fail during parsing so
  deployments cannot silently execute with degraded semantics.

  Non-node BPJS lane metadata is supported separately by the parser for
  `actorType` resolution only; collaborations, pools, participants, and
  message flows remain unsupported.
  """

  @supported_node_types MapSet.new(~w(
    blankStartEvent messageStartEvent signalStartEvent timerStartEvent conditionalStartEvent
    blankEndEvent errorEndEvent messageEndEvent signalEndEvent escalationEndEvent terminationEndEvent compensationEndEvent
    scriptTask externalTask userTask rulesTask callActivity manualTask sendTask receiveTask
    parallelGateway exclusiveGateway inclusiveGateway eventBasedGateway
    intermediateTimerEvent intermediateCatchTimerEvent intermediateCatchMessageEvent intermediateCatchSignalEvent intermediateCatchConditionalEvent intermediateCatchLinkEvent
    intermediateThrowMessageEvent intermediateThrowSignalEvent intermediateThrowErrorEvent intermediateThrowEscalationEvent intermediateThrowLinkEvent intermediateThrowCompensationEvent
    timerBoundaryEvent messageBoundaryEvent signalBoundaryEvent conditionalBoundaryEvent compensationBoundaryEvent errorBoundaryEvent escalationBoundaryEvent
    nonInterruptingTimerBoundaryEvent nonInterruptingMessageBoundaryEvent nonInterruptingSignalBoundaryEvent nonInterruptingConditionalBoundaryEvent
  ))

  @unsupported_reasons %{
    "subProcess" => "Embedded subprocess scopes are not implemented; use callActivity for a separate process.",
    "eventSubProcess" => "Event subprocesses are not implemented.",
    "transaction" => "Transaction subprocess and cancel semantics are not implemented.",
    "adHocSubProcess" => "Ad-hoc subprocesses are not implemented.",
    "complexGateway" => "Complex gateways are not implemented.",
    "cancelEndEvent" => "Cancel events are not implemented.",
    "cancelBoundaryEvent" => "Cancel events are not implemented.",
    "multipleStartEvent" => "Multiple events are not implemented.",
    "intermediateCatchMultipleEvent" => "Multiple events are not implemented.",
    "intermediateThrowMultipleEvent" => "Multiple events are not implemented.",
    "multipleEndEvent" => "Multiple events are not implemented.",
    "parallelMultipleStartEvent" => "Parallel multiple events are not implemented.",
    "intermediateCatchParallelMultipleEvent" => "Parallel multiple events are not implemented."
  }

  def supported_node_types, do: MapSet.to_list(@supported_node_types)
  def unsupported_node_types, do: Map.keys(@unsupported_reasons)

  def supported?(type), do: MapSet.member?(@supported_node_types, type)

  def unsupported_reason(type), do: Map.get(@unsupported_reasons, type)
end
