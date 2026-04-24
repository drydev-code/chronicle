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
| Generic task | Partial | Unknown nodes fall through; no dedicated generic task semantics. |
| Service task | Partial | Mapped to external service task. |
| User task | Partial | Mapped to external user task. |
| Script task | Implemented | JavaScript through Node worker pool. |
| Business rule task | Partial | DMN task exists; DMN coverage needs separate validation. |
| Send task | Missing | Message throw event exists, but no send-task activity semantics. |
| Receive task | Missing | Message catch event exists, but no receive-task activity semantics. |
| Manual task | Missing | No dedicated node. |
| Call activity | Partial | Sync/async child start plus sequential collection loop; completion persistence needs work. |
| Embedded subprocess | Missing | `SubProcess` is rejected by the supported-feature manifest. |
| Event subprocess | Missing | No scoped event subprocess support. |
| Transaction subprocess | Missing | No transaction/cancel semantics. |
| Ad-hoc subprocess | Missing | No ad-hoc semantics. |
| Loop activity | Missing | No standard activity loop characteristics. |
| Multi-instance activity | Partial | Only call activity sequential collection loop is visible. |

## Gateways

| BPMN gateway | Status | Notes |
| --- | --- | --- |
| Exclusive gateway | Implemented | Expression/default path support exists. |
| Parallel gateway | Implemented | Fork and simple join support exists. |
| Inclusive gateway | Partial | Fork exists; join is simplified and likely incomplete for complex graphs. |
| Event-based gateway | Missing | No parser/runtime support. |
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
| Conditional | Missing | Missing | N/A | N/A | Missing |
| Link | N/A | Missing | Missing | N/A | N/A |
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
- Boundary event structs exist, but runtime scheduling/registration for normal
  activity execution is not complete.

## Persistence And Recovery

| Capability | Status | Notes |
| --- | --- | --- |
| Start event persistence | Implemented | `EventStore.create/2` is called during instance init. |
| Incremental event flushing | Partial | Deltas are flushed in token processing, but several runtime transitions still lack event creation. |
| Timer elapsed persistence | Implemented | `TimerElapsed` is appended on timer firing. |
| Message/signal wait creation persistence | Missing | No durable wait-created event exists. |
| External task completion persistence | Implemented | Success path appends completion. |
| External task error/retry persistence | Missing | Error path resumes without a durable failure/retry event. |
| Call completion persistence | Missing | Parent resume does not append `CallCompleted`. |
| Fork/token-family persistence | Missing | `TokenFamilyCreated` exists but fork creation does not append it. |
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
