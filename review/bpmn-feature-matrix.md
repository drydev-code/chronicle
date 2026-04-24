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
| Service task | Partial | Mapped to external service task with durable create/complete/failure/cancel events; API/server cancellation routing still needs broader integration. |
| User task | Partial | Mapped to external user task with the same durability as service tasks; form/user lifecycle semantics are outside the current engine subset. |
| Script task | Implemented | JavaScript through Node worker pool. |
| Business rule task | Partial | DMN task exists; DMN coverage needs separate validation. |
| Send task | Implemented | First-class BPJS node; uses durable message throw behavior. |
| Receive task | Implemented | First-class BPJS node; uses durable message wait/handled behavior. |
| Manual task | Implemented | First-class modeled no-op with a replayable no-op completion event. |
| Call activity | Partial | Sync/async child start plus sequential collection loop; completion and explicit cancellation are persisted. Parent/child cancellation routing and restart tests still need coverage. |
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
| Inclusive gateway | Partial | Fork exists; join is simplified and likely incomplete for complex graphs. |
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
  False evaluations create durable waits that can be re-triggered explicitly
  through the instance API when variables change. Conditional start and boundary
  events remain unsupported.
- Boundary events can be created/registered for waiting activity tokens.
  Cancellation/removal is wired for external-task and call-activity completion/
  cancellation, script/rules result completion, process termination, and
  interrupting boundary trigger sibling cleanup. Token crash cleanup and
  external-task error-boundary propagation persist explicit boundary lifecycle
  events. Non-interrupting message/signal boundaries keep the activity wait
  open. Retry wait interruption timer cleanup, deeper activity interruption
  paths, and broader integration coverage remain incomplete.

## Persistence And Recovery

| Capability | Status | Notes |
| --- | --- | --- |
| Start event persistence | Implemented | `EventStore.create/2` is called during instance init. |
| Incremental event flushing | Partial | Deltas are flushed in token processing. Remaining gaps are boundary cleanup paths, retry cancellation/interruption cleanup, and API/server-level cancellation callers. |
| Timer elapsed persistence | Implemented | `TimerElapsed` is appended on timer firing. |
| Message/signal wait creation persistence | Implemented | `MessageWaitCreated` and `SignalWaitCreated` are emitted and replayed. |
| External task completion persistence | Implemented | Success path appends completion. |
| External task error/retry persistence | Partial | Failure appends `ExternalTaskCompletion(successful: false)`, matching error-boundary propagation appends `BoundaryEventTriggered` plus sibling `BoundaryEventCancelled`, retry timers are durable, and explicit cancellation appends `ExternalTaskCancellation`; server/API cancellation routing and restart tests remain. |
| Call completion persistence | Implemented | Parent resume appends `CallCompleted` before continuing. |
| Call cancellation persistence | Partial | Explicit call cancellation appends `CallCanceled`; parent/child lifecycle routing and restart tests remain. |
| Fork/token-family persistence | Implemented | Initial and fork-created tokens append `TokenFamilyCreated`; original fork token appends `TokenFamilyRemoved`. |
| Event-gateway timer cleanup | Implemented | Losing timer branches are canceled and recorded with `TimerCanceled` before `EventGatewayResolved` continues the token; restart/eviction tests are still needed. |
| Conditional wait re-trigger | Partial | `Instance.retrigger_conditionals/2` re-evaluates pending conditional catches with updated variables and persists the resulting `ConditionalEventEvaluated` decision; automatic variable-change/API integration is still missing. |
| Boundary cancellation persistence | Partial | `BoundaryEventCancelled` is appended before registry/timer mutation for external-task and call-activity completion/cancellation cleanup, script/rules result completion, process termination, interrupting boundary trigger sibling cleanup, and token crash cleanup. Replay removes canceled boundary indexes so restored registries/timers stay closed, and evicted collection handles boundary timer cancellation. Retry wait interruption cleanup, deeper activity interruption paths, and broader integration coverage still need work. |
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
