# Remaining Engine Work

Date: 2026-04-24

This file replaces the older source-code-review files. Items already
implemented in the current tree were intentionally dropped from this list.

## P0: Make Supported Semantics Durable

1. Add explicit persistent events for message and signal wait creation.
   `EvictedWaitRestorer` already expects `MessageWaitCreated` and
   `SignalWaitCreated`, but `PersistentData` and `TokenProcessor` do not emit
   them yet.

2. Persist call activity completion and cancellation before the parent token
   continues. `handle_cast({:child_completed, ...})` resumes the token, but no
   `CallCompleted` event is appended.

3. Persist external-task failures, retry decisions, and cancellation. The
   success path has `ExternalTaskCompletion`; the error path does not create a
   durable equivalent before retry/propagation.

4. Persist token family creation/removal during forks and joins. The event
   structs exist, but `handle_fork/3` does not append `TokenFamilyCreated`.

5. Wire boundary event lifecycle. Activity entry should register/schedule
   attached boundary events, and interruption/completion should cancel them.
   This includes both interrupting and non-interrupting variants.

## P1: Align Claims With BPMN Coverage

1. Keep README claims at "BPJS BPMN subset" until native XML, subprocess
   scopes, event-based gateways, compensation, and missing event types exist.

2. Add a supported-node manifest and parser/runtime tests for every claimed
   node type.

3. Keep compensation explicitly unsupported. No compensation event or handler
   implementation was found.

4. Either implement native BPMN XML parsing or keep `.bpmn` unsupported
   everywhere, including ZIP package behavior and API responses.

## P1: Fill Core BPMN Missing Pieces

1. Event-based gateways.
2. Embedded subprocesses with scoped variables and boundary events.
3. Event subprocesses, including interrupting and non-interrupting starts.
4. Conditional events.
5. Link events.
6. Compensation events and compensation handlers.
7. Cancel events and transaction subprocesses.
8. Multiple and parallel-multiple events.
9. Standard loop and multi-instance activity characteristics.
10. Send and receive tasks as first-class activities.

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
   waiting on message, signal, timer, external task, and call activity waits.

## Suggested Next Files To Implement

- `apps/engine/lib/chronicle/engine/persistent_data.ex`
- `apps/engine/lib/chronicle/engine/token_processor.ex`
- `apps/engine/lib/chronicle/engine/instance.ex`
- `apps/engine/lib/chronicle/engine/instance/event_replayer.ex`
- `apps/engine/lib/chronicle/engine/instance/wait_registry.ex`
- `apps/engine/test/chronicle/engine/instance_*_test.exs`

Start with durable wait-created events and call/external-task error persistence;
they strengthen the subset already claimed by the current runtime.
