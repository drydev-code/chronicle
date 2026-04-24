# Remaining Engine Work

Date: 2026-04-24

This file tracks work that is still missing after the current BPJS BPMN subset
durability pass. Items already implemented in the current tree are intentionally
not listed as open work.

## Current Durable Subset

The engine now has parser/runtime/replay support for:

- BPJS JSON diagrams only. Native BPMN XML remains out of scope.
- Start/end events, script tasks, rules tasks, external/user tasks, call
  activities, send tasks, receive tasks, and manual tasks.
- BPJS lanes as routing metadata for resolving external/user task `actorType`.
  Explicit node metadata wins over lane metadata; collaboration semantics are
  still unsupported.
- Exclusive, parallel, inclusive, and event-based gateways.
- Event-based gateway branches limited to message, receive-task, signal, and
  timer branches. Unsupported outgoing branches fail during parsing and at
  runtime validation.
- Intermediate message, signal, timer, conditional, and link catches.
- Conditional starts evaluated from variable payloads with selected
  `start_node_id` persisted on `ProcessInstanceStart`.
- Intermediate message, signal, error, escalation, compensation, and link
  throws.
- Standard activity loops with post-test condition evaluation, max-iteration
  guard, durable loop decisions, and replay.
- Compensation boundary handlers for completed compensatable activities, plus
  durable compensation request/start/completion replay.
- Durable wait-created events for message/signal waits.
- Durable external-task success/failure/cancellation events.
- Durable call completion/cancellation events.
- Durable token-family creation/removal for forks.
- Durable event-gateway activation/resolution and losing timer cancellation.
- Durable conditional catch evaluation and an explicit
  `Instance.retrigger_conditionals/2` command path.
- Boundary wait creation and durable cancellation for normal completion/
  cancellation of currently wait-capable activity paths, interrupting boundary
  trigger sibling cleanup, script/rules result cleanup, process termination,
  token crash cleanup, external-task error-boundary propagation, replay of
  `BoundaryEventCancelled`, retry-wait interruption cleanup, one-shot
  non-interrupting timer boundary replay, and evicted collection of boundary
  and retry timer cancellation.
- Graph-aware inclusive gateway joins that wait for selected same-family
  sibling tokens that can still reach the join.
- Durable variable updates through `Instance.update_variables/2` and the server
  API, followed by conditional re-triggering after the variable-change events
  persist and conditional boundary evaluation after variable-change events
  persist.

## P0: Supported-Subset Gaps

No P0 supported-subset gaps are currently open in the BPJS JSON runtime. The
completed P0 pass covered:

1. Retry-wait interruption by message, signal, and timer boundaries. The engine
   appends `TimerCanceled` for the retry timer before in-memory timer cleanup
   and boundary continuation. Replay and evicted wait collection do not restore
   canceled retry timers.

2. Boundary lifecycle integration through `Instance` APIs. Normal external-task
   and call completion/cancellation append `BoundaryEventCancelled` before
   activity continuation. Interrupting message/signal/timer boundaries append
   `BoundaryEventTriggered` plus sibling `BoundaryEventCancelled` before the
   token moves. Non-interrupting message/signal boundaries keep the original
   activity wait open and stay registered. Non-interrupting timer boundaries
   are defined as one-shot; each trigger closes that timer registration.

3. Restart/eviction coverage for `ExternalTaskCancellation`, `CallCanceled`,
   `BoundaryEventCancelled`, retry timer cancellation, and variable-update /
   conditional re-trigger replay.

4. Server/API cancellation wiring for external tasks and durable variable
   update routing. AMQP task completion/failure/cancellation routes through
   synchronous engine commands for resident instances so acknowledgement occurs
   only after durable append succeeds; evicted instances are queued through
   their load cells for restore.

5. Durable variable-change conditional re-trigger via `VariablesUpdated` events
   and EventReplayer support.

6. Inclusive gateway joins with graph-aware selected-path waiting.

## P1: BPMN Coverage Still Missing

1. Embedded subprocesses with scoped variables and boundary events.
2. Event subprocesses, including interrupting and non-interrupting starts.
3. Event subprocess conditional starts and event-subprocess boundary semantics.
4. Cancel events and transaction subprocesses.
5. Multiple and parallel-multiple events.
6. Sequential and parallel multi-instance activity characteristics with
   completion conditions. Current sequential collection loop is call-activity
   specific, not general BPMN multi-instance support.
7. Collaboration, pools, participants, message flows, BPMN data objects, and
   data associations. Lanes are supported only as `actorType` metadata.
8. Broader event-based gateway branch support beyond message/receive/signal/
    timer only if BPJS models require it.

## P1: Claims And Packaging

1. Keep README claims at "strict BPJS BPMN subset" until native XML,
   subprocess scopes, compensation, missing event types, and full BPMN
   lifecycle semantics exist.

2. Keep `.bpmn` unsupported everywhere, including ZIP package behavior and API
   responses, unless native XML import is intentionally implemented.

3. Add parser, runtime, replay, and restart/eviction tests before marking any
   SupportedFeatures entry as supported.

4. Keep transaction/cancel semantics explicitly unsupported until they are
   implemented separately from compensation.

## P2: Production Safety

1. Replace destructive table-dropping migrations with additive migrations or a
   one-time explicit migration tool.

2. Replace the current auth plug with real authentication and authorization.
   Presence of `x-user-id` is useful for local integration but not sufficient
   for production.

3. Remove, compile-gate, or config-gate `POST /api/deployment/mock` so local
   filesystem reads cannot exist in production.

4. Decide whether startup should restore all active instances resident or
   support evicted-only wait routing. If evicted-only routing is desired,
   finish and wire `EvictedWaitRestorer`.

5. Add integration tests that kill/restart the engine while instances are
   waiting on message, signal, timer, external task, call activity, conditional
   catch, event-based gateway, and boundary waits.

## Suggested Next Batch

The next implementation phase should focus on scoped subprocess behavior and
the remaining unsupported BPMN event families:

1. Embedded subprocesses with scoped variables and scoped boundary events.
2. Event subprocesses, including interrupting/non-interrupting starts.
3. Transaction subprocesses with cancel semantics.
4. Multiple and parallel-multiple events.
5. Standard sequential/parallel multi-instance activity characteristics.

Keep the same rule for every expansion: parseable, executable, replayable, and
covered by restart/eviction tests before claiming support.
