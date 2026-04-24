# Next Phase Handoff Prompt

You are working in `D:\Drydev\chronicle`.

Goal: implement the next Chronicle BPJS BPMN subset phase completely while
preserving event-sourcing/CQRS semantics.

Start by reading:

- `README.md`
- `review/bpmn-feature-matrix.md`
- `review/remaining-engine-work.md`
- `review/next-phase-bpmn-roadmap.md`
- `apps/engine/lib/chronicle/engine/diagrams/parser.ex`
- `apps/engine/lib/chronicle/engine/diagrams/supported_features.ex`
- `apps/engine/lib/chronicle/engine/diagrams/definition.ex`
- `apps/engine/lib/chronicle/engine/instance.ex`
- `apps/engine/lib/chronicle/engine/token_processor.ex`
- `apps/engine/lib/chronicle/engine/instance/boundary_lifecycle.ex`
- `apps/engine/lib/chronicle/engine/instance/wait_registry.ex`
- `apps/engine/lib/chronicle/engine/instance/event_replayer.ex`
- `apps/engine/lib/chronicle/engine/evicted_wait_restorer.ex`
- `apps/engine/lib/chronicle/engine/persistent_data.ex`
- `apps/engine/lib/chronicle/engine/nodes/start_events.ex`
- `apps/engine/lib/chronicle/engine/nodes/boundary_events.ex`
- `apps/engine/lib/chronicle/engine/nodes/activity.ex`
- `apps/engine/lib/chronicle/engine/nodes/external_task.ex`
- `apps/engine/lib/chronicle/engine/nodes/call_activity.ex`
- `apps/server/lib/chronicle/server/host/external_task_router.ex`
- `apps/server/lib/chronicle/server/messaging/message_consumer.ex`
- `apps/server/lib/chronicle/server/web/router.ex`

Current baseline:

- Commit: `e6a6b4c Complete BPJS supported subset P0 work`.
- Last required verification passed:
  - `docker compose --profile test build test`
  - `docker compose --profile test run --rm test`
- Engine: 76 tests, 0 failures.
- Server: 9 tests, 0 failures.
- Known harmless log noise: `elixir_uuid` Bitwise deprecation, `recon` OTP
  float warning, server MyXQL databus access-denied logs, and intentional
  negative-path engine error logs from tests.

Hard constraints:

- Do not implement native BPMN XML import. Chronicle targets BPJS JSON diagrams.
- Event log is source of truth. Commands must append durable events before
  mutating projections, continuing tokens, publishing PubSub/AMQP effects, or
  acknowledging work.
- Query/read paths must not mutate workflow state.
- Unsupported BPMN features must fail during parsing/runtime validation.
- Update `SupportedFeatures` only when parseable, executable, replayable, and
  tested.
- Add `PersistentData` structs for replay-critical transitions.
- Update `EventReplayer` for every new persistent transition.
- Keep side effects queued until durable append succeeds.
- Keep README and review docs aligned.

Implement all items in `review/next-phase-bpmn-roadmap.md`:

1. Lanes as `actorType` metadata:
   - Parse BPJS lane metadata and lane-node membership.
   - Resolve node actor type from explicit node metadata first, lane metadata
     second, existing defaults last.
   - Include actor type in external/user task publication payloads.
   - Add parser/runtime/server tests.
   - Keep collaboration, pools, participants, and message flows unsupported.

2. Conditional start events:
   - Parse and validate conditional start event nodes.
   - Add a public command/API for evaluating conditional starts from variable
     payloads or business-key scoped variable updates.
   - Persist replay-critical start decisions. `ProcessInstanceStart.start_node_id`
     must identify the conditional start node.
   - Add false-condition, true-condition, and replay tests.
   - Keep event subprocess starts out of scope unless explicitly designed.

3. Conditional boundary events:
   - Parse interrupting and non-interrupting conditional boundary event nodes.
   - Register conditional boundary waits for the current wait-capable activity
     subset.
   - Evaluate open conditional boundaries only after durable variable update
     events persist.
   - Interrupting conditional boundaries must append `BoundaryEventTriggered`,
     sibling `BoundaryEventCancelled`, and retry `TimerCanceled` where relevant
     before cleanup/continuation.
   - Define non-interrupting conditional boundary semantics. Prefer one-shot
     unless BPJS has explicit repeat metadata.
   - Add replay and evicted wait collection tests.

4. Standard loop activity characteristics:
   - Parse BPJS standard loop metadata on supported activities.
   - Support condition plus max-iteration guard.
   - Choose and document pre-test/post-test semantics. Prefer post-test if BPJS
     has no explicit marker.
   - Persist replay-critical loop iteration/condition transitions.
   - Add runtime, replay, and boundary-cleanup tests.
   - Keep multi-instance activity characteristics out of scope.

5. Compensation events:
   - Implement compensation only with durable handler registration/request/start
     completion semantics.
   - Parse supported compensation boundary/throw/end shapes; reject unsupported
     shapes.
   - Record completed compensatable activity instances in the event log.
   - Start compensation handlers deterministically and idempotently across
     replay/restart.
   - Add replay, eviction, and side-effect ordering tests.
   - Keep transaction subprocess/cancel semantics out of scope unless explicitly
     designed separately.

Before final response:

- Run:
  - `docker compose --profile test build test`
  - `docker compose --profile test run --rm test`
- Commit the completed work.
- Summarize implemented changes.
- Summarize BPMN features still intentionally unsupported.
- Mention any tests that could not be run.
