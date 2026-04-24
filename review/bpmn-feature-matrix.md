# BPMN Feature Matrix

Date: 2026-04-24

Status values:

- Implemented: visible parse and runtime behavior exists.
- Partial: some parser/runtime support exists, but semantics are incomplete.
- Missing: no meaningful implementation found.
- Unsupported: intentionally rejected or documented as not wired.

## Process Model

| BPMN area | Status | Notes |
| --- | --- | --- |
| Executable process | Partial | BPJS process definitions are executable. Native BPMN XML is not. |
| BPMN XML import | Unsupported | `.bpmn` is rejected as XML unsupported. |
| Collaboration / pools / lanes | Missing | No model/runtime for participants, lanes, or message flows. |
| Sequence flow | Implemented | Connections drive token movement. |
| Data objects / data associations | Missing | Variables are engine maps, not BPMN data objects/associations. |
| Process versioning | Implemented | Restore uses recorded process version. |
| Deployment persistence | Partial | BPJS persisted/rehydrated; DMN persistence appears ETS/runtime-focused. |

## Activities

| BPMN element | Status | Notes |
| --- | --- | --- |
| Generic task | Unsupported | Unknown node types are rejected instead of falling through; no dedicated generic task semantics. |
| Service task | Partial | Mapped to external service task with durable create/complete/failure/cancel events; HTTP/API and AMQP cancellation routing exists. Domain-specific service-task semantics remain outside the engine subset. |
| User task | Partial | Mapped to external user task with the same durability as service tasks; form/user lifecycle semantics are outside the current engine subset. HTTP/API and AMQP cancellation routing exists. |
| Script task | Implemented | JavaScript through Node worker pool. |
| Business rule task | Partial | DMN task exists; DMN coverage needs separate validation. |
| Send task | Implemented | First-class BPJS node; uses durable message throw behavior. |
| Receive task | Implemented | First-class BPJS node; uses durable message wait/handled behavior. |
| Manual task | Implemented | First-class modeled no-op with a replayable no-op completion event. |
| Call activity | Partial | Sync/async child start plus sequential collection loop; completion and explicit cancellation are persisted and replay-tested. Broader parent/child operational routing remains domain-specific. |
| Embedded subprocess | Missing | `SubProcess` is rejected by the supported-feature manifest. |
| Event subprocess | Missing | No scoped event subprocess support. |
| Transaction subprocess | Missing | No transaction/cancel semantics. |
| Ad-hoc subprocess | Missing | No ad-hoc semantics. |
| Loop activity | Missing | No standard activity loop characteristics. |
| Multi-instance activity | Partial | Only call-activity-specific sequential collection looping exists; standard BPMN loop and multi-instance characteristics are missing. |

## Gateways

| BPMN gateway | Status | Notes |
| --- | --- | --- |
| Exclusive gateway | Implemented | Expression/default path support exists. |
| Parallel gateway | Implemented | Fork and simple join support exists. |
| Inclusive gateway | Implemented | Fork selects all true branches; joins are graph-aware and wait only for selected same-family sibling tokens that can still reach the join. |
| Event-based gateway | Partial | Supports message, receive-task, signal, and timer branches in BPJS JSON with strict outgoing-branch validation and durable activation/resolution. Losing timer branches are canceled when another branch wins; restart tests and broader BPMN event branches remain missing. |
| Complex gateway | Missing | No parser/runtime support. |

## Events

| BPMN event type | Start | Intermediate catch | Intermediate throw | End | Boundary |
| --- | --- | --- | --- | --- | --- |
| None | Implemented | N/A | N/A | Implemented | N/A |
| Message | Implemented | Implemented | Implemented | Implemented | Partial |
| Timer | Partial | Implemented | N/A | N/A | Partial |
| Signal | Implemented | Implemented | Implemented | Implemented | Partial |
| Error | Partial | N/A | Partial | Partial | Partial |
| Escalation | Partial | N/A | Partial | Partial | Partial |
| Conditional | Missing | Partial | N/A | N/A | Missing |
| Link | N/A | Implemented | Implemented | N/A | N/A |
| Compensation | N/A | Missing | Missing | Missing | Missing |
| Cancel | N/A | Missing | Missing | Missing | Missing |
| Terminate | N/A | N/A | N/A | Implemented | N/A |
| Multiple | Missing | Missing | Missing | Missing | Missing |
| Parallel multiple | Missing | Missing | Missing | Missing | Missing |

Notes:

- Error/escalation start events are normalized as blank start events in the
  parser, so they are not true BPMN error/escalation start semantics.
- Throwing error/escalation completes with `CompletionData`, rather than
  propagating through BPMN scopes.
- Conditional intermediate events are expression-gated and persist evaluation.
  False evaluations create durable waits that can be re-triggered explicitly,
  or via the durable variable-update API, when variables change. Conditional
  start and boundary events remain unsupported.
- Boundary events can be created/registered for waiting activity tokens.
  Cancellation/removal is wired for external-task and call-activity completion/
  cancellation, script/rules result completion, process termination,
  interrupting boundary trigger sibling cleanup, retry-wait interruption, token
  crash cleanup, and external-task error-boundary propagation. Non-interrupting
  message/signal boundaries keep the activity wait open and remain registered.
  Non-interrupting timer boundaries are one-shot and close their timer
  registration after the trigger is persisted.

## Persistence And Recovery

| Capability | Status | Notes |
| --- | --- | --- |
| Start event persistence | Implemented | `EventStore.create/2` is called during instance init. |
| Incremental event flushing | Implemented | Deltas are flushed in token processing and command paths before projection mutation, continuation, PubSub/AMQP effects, or acknowledgement-sensitive routing. |
| Timer elapsed persistence | Implemented | `TimerElapsed` is appended on timer firing. |
| Message/signal wait creation persistence | Implemented | `MessageWaitCreated` and `SignalWaitCreated` are emitted and replayed. |
| External task completion persistence | Implemented | Success path appends completion. |
| External task error/retry persistence | Implemented | Failure appends `ExternalTaskCompletion(successful: false)`, matching error-boundary propagation appends `BoundaryEventTriggered` plus sibling `BoundaryEventCancelled`, retry timers are durable, interrupting boundaries append `TimerCanceled` for open retry timers, and explicit cancellation appends `ExternalTaskCancellation`. |
| Call completion persistence | Implemented | Parent resume appends `CallCompleted` before continuing. |
| Call cancellation persistence | Implemented | Explicit call cancellation appends `CallCanceled`; replay and evicted wait collection close canceled call waits. |
| Fork/token-family persistence | Implemented | Initial and fork-created tokens append `TokenFamilyCreated`; original fork token appends `TokenFamilyRemoved`. |
| Event-gateway timer cleanup | Implemented | Losing timer branches are canceled and recorded with `TimerCanceled` before `EventGatewayResolved` continues the token; replay coverage verifies canceled timer branches stay closed after restore. |
| Conditional wait re-trigger | Implemented | `Instance.retrigger_conditionals/2` re-evaluates pending conditional catches; `Instance.update_variables/2` and the HTTP variable update route append durable `VariablesUpdated` events before mutating token variables and re-triggering conditionals. |
| Boundary cancellation persistence | Implemented | `BoundaryEventCancelled` is appended before registry/timer mutation for external-task and call-activity completion/cancellation cleanup, script/rules result completion, process termination, interrupting boundary trigger sibling cleanup, retry timer interruption, and token crash cleanup. Replay removes canceled boundary indexes so restored registries/timers stay closed, and evicted collection handles boundary and retry timer cancellation. |
| Exact-version restore | Implemented | Replayer uses `DiagramStore.get(name, version, tenant)`. |
| Eviction duplicate prevention | Implemented | Lifecycle appends only event deltas. |
| Evicted-only startup recovery | Missing | Module docs state this is not wired. |

## Standards Position

Chronicle currently looks like a focused BPMN-inspired runtime for BPJS
definitions, not a full BPMN 2.0 conformance engine. A precise public claim
would be:

> Chronicle executes a strict subset of BPMN 2.0 modeled in BPJS JSON, with
> external tasks, scripts, rules tasks, call activities, common gateways, and
> common message/signal/timer events.
