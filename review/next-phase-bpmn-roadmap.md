# Next Phase BPMN Roadmap

Date: 2026-04-24

This phase intentionally stays within Chronicle's BPJS JSON target. Do not add
native BPMN XML import. Every newly claimed feature must be parseable,
executable, replayable, and covered by focused runtime plus restart/eviction
tests before updating `SupportedFeatures` or public docs.

## Goal

Implement the next practical BPJS BPMN subset expansion:

1. Lanes as `actorType` metadata in the Chronicle schema.
2. Conditional start and conditional boundary events.
3. Standard loop activity characteristics.
4. Compensation events and compensation handlers.

Preserve the current event-sourcing/CQRS invariants:

- Durable events are appended before mutating workflow projections, continuing
  tokens, publishing PubSub/AMQP effects, or acknowledging external work.
- Query/read paths never mutate workflow state.
- Unsupported shapes fail during parsing or runtime validation.
- Replay-critical behavior gets `PersistentData` structs and EventReplayer
  support.
- Eviction/restart collection must not restore closed waits.

## Phase 1: Lanes As actorType

### Desired Semantics

Lanes are supported as assignment/routing metadata, not full BPMN collaboration
semantics. Chronicle should treat lanes as a way to resolve an `actorType` for
nodes, especially external/user tasks.

Initial scope:

- Parse BPJS lane metadata and lane-node membership.
- Attach resolved lane metadata to nodes or definition indexes.
- Resolve `actorType` precedence:
  1. explicit node property / vendor extension actor type,
  2. lane actor type,
  3. existing default behavior.
- Include actor type in external/user task publication payloads.
- Preserve actor type across replay if it affects emitted work.

Out of scope:

- BPMN collaborations, pools, participants, message flows.
- Lane-based authorization in the engine.
- Runtime reassignment of lanes.

### Likely Files

- `apps/engine/lib/chronicle/engine/diagrams/parser.ex`
- `apps/engine/lib/chronicle/engine/diagrams/definition.ex`
- `apps/engine/lib/chronicle/engine/nodes/*.ex`
- `apps/engine/lib/chronicle/engine/token_processor.ex`
- `apps/server/lib/chronicle/server/host/external_tasks/*.ex`
- `apps/server/lib/chronicle/server/messaging/*publisher.ex`
- Parser/runtime/server tests under `apps/engine/test` and `apps/server/test`

### Acceptance Tests

- BPJS with lane membership parses into lane/actor metadata.
- Explicit node actor type overrides lane actor type.
- User/external task created from a lane carries actor type in PubSub/AMQP
  payloads.
- Replay of an instance waiting at an external/user task keeps enough metadata
  to re-emit or inspect assignment consistently.

## Phase 2: Conditional Start Events

### Desired Semantics

Conditional start events allow a deployed BPJS definition to start when a
variable-change command/event satisfies the start condition.

Initial scope:

- Parse supported conditional start event nodes.
- Validate condition expression exists and unsupported variants fail.
- Add a public command/API that evaluates conditional starts for a tenant and
  starts matching definitions only after durable variable-change intent is
  recorded where required.
- Persist replay-critical start decision data. At minimum, the resulting
  `ProcessInstanceStart` must record the selected conditional start node and
  start parameters.

Open design decision:

- Whether conditional starts are evaluated against a tenant/global variable
  store, a business-key scoped variable update, or only explicit API payloads.
  Prefer business-key scoped payloads if this needs correlation semantics.

Out of scope:

- Event subprocess starts.
- Conditional starts inside native BPMN XML.
- Background polling unless a concrete caller requires it.

### Likely Files

- `apps/engine/lib/chronicle/engine/diagrams/parser.ex`
- `apps/engine/lib/chronicle/engine/diagrams/supported_features.ex`
- `apps/engine/lib/chronicle/engine/nodes/start_events.ex`
- `apps/engine/lib/chronicle/engine/instance.ex`
- `apps/server/lib/chronicle/server/web/controllers/process_instance_controller.ex`
- `apps/server/lib/chronicle/server/web/router.ex`
- `apps/engine/test/chronicle/engine/diagrams/*`
- `apps/engine/test/chronicle/engine/instance/*`

### Acceptance Tests

- Conditional start parses and unsupported malformed conditional starts fail.
- False condition does not start an instance.
- True condition starts from the conditional start node and persists
  `ProcessInstanceStart.start_node_id`.
- Restart/replay uses the recorded start node and does not fall back to the
  blank start event.

## Phase 3: Conditional Boundary Events

### Desired Semantics

Conditional boundary events behave like the existing message/signal/timer
boundary lifecycle, driven by durable variable updates and explicit conditional
re-triggering.

Initial scope:

- Parse interrupting and non-interrupting conditional boundary event nodes.
- Register conditional boundary waits for currently wait-capable activities.
- On durable variable update, evaluate open conditional boundaries after the
  `VariablesUpdated` event persists.
- Interrupting conditional boundaries append `BoundaryEventTriggered`, cancel
  sibling boundary registrations with `BoundaryEventCancelled`, close activity
  retry timers with `TimerCanceled` when present, then continue on the boundary
  path.
- Non-interrupting conditional boundaries create a sibling boundary token and
  keep the original activity wait open. Decide whether they are repeatable or
  one-shot and persist/replay that behavior explicitly.

Recommended semantics:

- Non-interrupting conditional boundaries should be repeatable only if BPJS
  models express repeat behavior explicitly. Otherwise make them one-shot, like
  non-interrupting timer boundaries, to avoid accidental infinite spawning.

Out of scope:

- Conditional event subprocess starts.
- Native BPMN XML conditional event definitions.

### Likely Files

- `apps/engine/lib/chronicle/engine/nodes/boundary_events.ex`
- `apps/engine/lib/chronicle/engine/nodes/activity.ex`
- `apps/engine/lib/chronicle/engine/diagrams/parser.ex`
- `apps/engine/lib/chronicle/engine/instance.ex`
- `apps/engine/lib/chronicle/engine/instance/boundary_lifecycle.ex`
- `apps/engine/lib/chronicle/engine/instance/wait_registry.ex`
- `apps/engine/lib/chronicle/engine/instance/event_replayer.ex`
- `apps/engine/lib/chronicle/engine/evicted_wait_restorer.ex`

### Acceptance Tests

- Conditional boundary create/cancel/trigger events are durable and replayable.
- Interrupting conditional boundary through `Instance.update_variables/2`
  persists trigger/cancel events before moving the token.
- Non-interrupting conditional boundary keeps the activity wait open and
  replays its chosen one-shot/repeat semantics.
- Evicted wait collection restores open conditional boundary waits and does not
  restore triggered/canceled ones.

## Phase 4: Standard Loop Activity Characteristics

### Desired Semantics

Support standard BPMN-style loop behavior for supported activities, distinct
from multi-instance and distinct from the call-activity collection loop already
in the tree.

Initial scope:

- Parse a BPJS loop characteristic on supported activity nodes.
- Support condition plus max-iteration guard.
- Decide pre-test vs post-test semantics from schema. If BPJS has no explicit
  marker, choose post-test so the activity executes once before evaluating the
  loop continuation condition.
- Persist replay-critical loop transitions, including iteration number and
  condition result.
- Preserve existing completion/cancellation/boundary behavior per iteration.

Out of scope:

- Sequential/parallel multi-instance.
- Completion conditions across multiple instances.
- Looping gateways/events unless explicitly modeled as supported activities.

### Suggested PersistentData

- `LoopIterationStarted` or equivalent if iteration start affects replay.
- `LoopConditionEvaluated` with token, current node, iteration, condition,
  matched/continue boolean, and target/next node.

Prefer one event only if it is enough to replay exactly.

### Acceptance Tests

- Activity loops until condition is false and then continues to the outgoing
  path.
- Max-iteration guard prevents unbounded loops and has deterministic failure or
  completion behavior.
- Replay after several loop iterations restores the correct token parameters,
  current node, and iteration counter.
- Boundary completion/cancellation events are per-iteration and do not leak
  stale registrations.

## Phase 5: Compensation Events

### Desired Semantics

Compensation should be implemented as scoped, durable compensation handling,
not as a simple throw event shortcut.

Initial scope:

- Parse compensation boundary events and compensation throw/end events only for
  the subset of activities where handlers can be modeled and replayed.
- Record completed compensatable activity instances in the event log.
- Throwing compensation selects eligible completed activity instances in a
  deterministic order.
- Start compensation handler tokens durably.
- Ensure compensation is idempotent across replay/restart.

Out of scope for first pass:

- Transaction subprocess/cancel semantics.
- Full BPMN scope hierarchy unless implemented as part of subprocess support.
- Compensation across process boundaries unless explicitly needed.

### Suggested PersistentData

- `CompensationHandlerRegistered`
- `CompensatableActivityCompleted`
- `CompensationRequested`
- `CompensationHandlerStarted`
- `CompensationHandlerCompleted`

The exact set can be smaller if replay fidelity is still complete.

### Acceptance Tests

- Unsupported compensation shapes fail parse/runtime validation.
- Completed compensatable activity can be compensated once.
- Replay after compensation request does not start duplicate handlers.
- Eviction/restart does not lose pending compensation handlers.
- Compensation side effects are queued until durable append succeeds.

## Documentation Updates Required At The End

- `README.md`
- `review/bpmn-feature-matrix.md`
- `review/remaining-engine-work.md`
- `apps/engine/lib/chronicle/engine/diagrams/supported_features.ex`

Update these only when the feature is parseable, executable, replayable, and
tested.
