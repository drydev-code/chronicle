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
- Exclusive, parallel, inclusive, and event-based gateways.
- Event-based gateway branches limited to message, receive-task, signal, and
  timer branches. Unsupported outgoing branches fail during parsing and at
  runtime validation.
- Intermediate message, signal, timer, conditional, and link catches.
- Intermediate message, signal, error, escalation, and link throws.
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
  `BoundaryEventCancelled`, and evicted collection of boundary timer
  cancellation.

## P0: Supported-Subset Gaps

1. Finish the remaining boundary lifecycle edge cases. Durable cancellation is
   now wired through external-task/call completion and cancellation,
   script/rules result completion, process termination, and interrupting
   boundary trigger sibling cleanup. Token crash cleanup and external-task
   error-boundary propagation append durable boundary lifecycle events before
   registry/timer cleanup. Remaining paths include retry-wait interruption
   timer cancellation semantics and any deeper activity interruption paths not
   covered by the current wait-capable subset. Every non-triggered open
   boundary registration should continue to append `BoundaryEventCancelled`
   before in-memory registry/timer cleanup.

2. Add restart/eviction tests for newly durable transitions. Current focused
   tests cover parser/runtime behavior, but the following still need replay
   tests:
   - Conditional wait created, instance restored, condition re-triggered, token
     continues only after persisted `ConditionalEventEvaluated`.
   - Event-based gateway created with timer plus message/signal branch, instance
     restored, non-timer branch wins, losing timer is persisted as
     `TimerCanceled` and does not re-fire after another restore.
   - `ExternalTaskCancellation` and `CallCanceled` close open waits after
     restore/eviction.
   - `BoundaryEventCancelled` keeps restored boundary registries/timers closed.
     Direct instance replay is covered, and evicted wait collection now covers
     boundary timers; broader load-cell end-to-end coverage is still useful.

3. Wire explicit cancellation through service/API layers. Engine APIs exist for
   `Instance.cancel_external_task/4` and `Instance.cancel_call/3`, but server
   routes, AMQP acknowledgements, parent/child lifecycle callers, and operational
   endpoints still need to use them where cancellation is possible.

4. Integrate conditional re-triggering with variable-change workflows. The
   engine has an explicit command, but there is still no public variable-update
   command/API, scheduler, or registry route that automatically calls it when
   relevant variables change.

5. Validate retry timer cleanup under interruption. Retry timers are now created
   durably and external-task retry keeps activity boundary registrations open,
   but an interrupting boundary that fires while the retry timer is open still
   needs explicit `TimerCanceled` semantics and tests.

6. Tighten inclusive gateway join semantics. Inclusive fork exists, but joins
   are still simplified and can be wrong for complex graph shapes.

## P1: BPMN Coverage Still Missing

1. Embedded subprocesses with scoped variables and boundary events.
2. Event subprocesses, including interrupting and non-interrupting starts.
3. Conditional start events and conditional boundary events.
4. Compensation events and compensation handlers.
5. Cancel events and transaction subprocesses.
6. Multiple and parallel-multiple events.
7. Standard loop activity characteristics.
8. Sequential and parallel multi-instance activity characteristics with
   completion conditions. Current sequential collection loop is call-activity
   specific, not general BPMN multi-instance support.
9. Collaboration, pools, lanes, message flows, BPMN data objects, and data
   associations.
10. Broader event-based gateway branch support beyond message/receive/signal/
    timer only if BPJS models require it.

## P1: Claims And Packaging

1. Keep README claims at "strict BPJS BPMN subset" until native XML,
   subprocess scopes, compensation, missing event types, and full BPMN
   lifecycle semantics exist.

2. Keep `.bpmn` unsupported everywhere, including ZIP package behavior and API
   responses, unless native XML import is intentionally implemented.

3. Add parser, runtime, replay, and restart/eviction tests before marking any
   SupportedFeatures entry as supported.

4. Keep compensation explicitly unsupported until both compensation events and
   compensation handlers are implemented and replayable.

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

Start with boundary lifecycle completion and replay tests. The highest-leverage
files are:

- `apps/engine/lib/chronicle/engine/token_processor.ex`
- `apps/engine/lib/chronicle/engine/instance.ex`
- `apps/engine/lib/chronicle/engine/instance/wait_registry.ex`
- `apps/engine/lib/chronicle/engine/instance/event_replayer.ex`
- `apps/engine/lib/chronicle/engine/instance/token_state.ex`
- `apps/engine/test/chronicle/engine/instance_*_test.exs`
- `apps/engine/test/chronicle/engine/token_processor_bpmn_features_test.exs`
- `apps/engine/test/chronicle/engine/evicted_wait_restore_test.exs`

Recommended first tests:

- External task with timer/message/signal boundaries completes normally and
  appends `BoundaryEventCancelled` for every non-triggered boundary before the
  external task completion event is acted on.
- Add integration-level coverage for interrupting boundary trigger persistence
  through `Instance` message/signal/timer commands. Focused registry and replay
  tests now cover sibling cleanup and closed restoration.
- Non-interrupting boundary fires and keeps the activity wait open while
  preserving or rescheduling the expected boundary registrations. Focused
  registry coverage exists for message boundaries; timer rescheduling still
  needs explicit semantics.
- Restore after `BoundaryEventCancelled` does not re-register the canceled
  timer/message/signal boundary. Direct `EventReplayer` coverage exists.
- Restore after event-gateway message win does not re-register the canceled
  timer branch. Direct `EventReplayer` coverage exists.
