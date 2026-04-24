# Workflow Engine Completeness Review

Date: 2026-04-24

## Verdict

No. Chronicle is not a complete BPMN 2.0 workflow engine if the target is the
standard BPMN executable feature set. It implements a useful core subset:

- process instances as OTP actors
- token execution
- none/message/signal/timer start events
- none/message/signal/escalation/error/terminate end events
- timer/message/signal intermediate catch events
- message/signal/error/escalation intermediate throw events
- exclusive, parallel, and inclusive gateways
- script, business rules, service/user external tasks, and call activities
- event-store persistence, restore, deployment persistence, and eviction basics

The remaining gaps are mostly in three categories:

1. BPMN coverage: many standard node/event/activity types are absent.
2. Semantics: several parsed feature claims are only partial at runtime.
3. Production runtime: persistence and recovery are improved, but some wait,
   migration, deployment, and operational concerns still need hardening.

## Current Strengths

- `apps/engine/lib/chronicle/engine/diagrams/parser.ex` parses the supported
  BPJS JSON shape and rejects duplicate node IDs before map conversion.
- `apps/engine/lib/chronicle/engine/instance.ex` persists
  `ProcessInstanceStart` synchronously and flushes event deltas during token
  processing.
- `apps/engine/lib/chronicle/engine/instance/event_replayer.ex` restores using
  the exact recorded process version rather than silently using latest.
- `apps/engine/lib/chronicle/engine/diagrams/diagram_store.ex` persists raw
  BPJS deployments and rehydrates them on restart.
- `apps/engine/lib/chronicle/engine/eviction_manager.ex` starts load cells
  under `Chronicle.Engine.LoadCellSupervisor`.
- `apps/server/lib/chronicle/server/web/router.ex` now routes API endpoints
  through auth/admin pipelines.
- `apps/server/lib/chronicle/server/host/deployment/manager.ex` rejects direct
  `.bpmn` XML uploads instead of feeding them to the JSON parser.

## Major Missing BPMN Coverage

- XML BPMN import/export is not implemented. `.bpmn` is recognized as
  unsupported; executable diagrams are BPJS JSON only.
- BPMN collaboration/pool/lane/message-flow semantics are not represented.
- Event subprocesses are not represented.
- Embedded subprocesses, ad-hoc subprocesses, and transaction subprocesses are
  not represented. `SubProcess` is rejected by the supported-feature manifest.
- Event-based gateways and complex gateways are absent.
- Conditional, link, compensate, cancel, multiple, and parallel-multiple events
  are absent.
- Receive tasks, send tasks, manual tasks, business-process tasks, and generic
  task/service implementation variants are absent or collapsed into external
  task/script/rules task behavior.
- Standard loop, parallel multi-instance, and completion-condition semantics are
  absent. Only call activity sequential collection looping appears.
- Compensation handling is not implemented and is rejected as unsupported.
- Boundary events are parsed, but runtime registration is incomplete for
  timer/message/signal boundary behavior.

## Major Runtime Gaps

- Message and signal waits are not represented by explicit persisted
  wait-created events. Restore currently infers some waits from token/node
  position, while `EvictedWaitRestorer` already documents that explicit
  `MessageWaitCreated` and `SignalWaitCreated` events are expected but absent.
- Boundary event handling is incomplete. The parser defines boundary structs,
  and `WaitRegistry` can consume boundary timer/message paths, but there is no
  visible activity-enter hook that schedules/registers attached timer, message,
  or signal boundaries.
- External task error retry persistence is incomplete. `error_external_task/5`
  resumes a token, but the code path does not append a durable
  `ExternalTaskCompletion` failure event or retry event before retrying.
- Call activity completion persistence is incomplete. Child completion resumes
  parent tokens, but the parent does not append `CallCompleted` before
  continuing.
- Token creation/fork persistence is incomplete. `TokenFamilyCreated` exists,
  but fork-created tokens are not currently appended as durable events.
- End-event semantics for thrown error/escalation are modeled as process/token
  completion, not BPMN propagation through enclosing scopes/event subprocesses.
- Inclusive join behavior is simplified to "wait for all non-recursive inputs";
  full BPMN inclusive-join activation semantics require reachability analysis
  over active upstream paths.
- Timer semantics are duration-focused. Cron, cycles, calendar dates, time
  zones, and repeating timer semantics are not fully implemented.
- Script execution uses raw Node.js subprocesses and is documented as trusted
  only; this is not suitable for untrusted tenant BPMN script tasks.

## Production Hardening Gaps

- Migrations still drop `ActiveProcessInstances`, `CompletedProcessInstances`,
  and `TerminatedProcessInstances` before recreating them.
- Auth exists, but it is a simple `x-user-id` presence check with no roles or
  authorization policy.
- The mock deployment endpoint still exists in the admin scope. It should be
  dev/test only or removed from production builds.
- `Chronicle.Engine.EvictedWaitRestorer` explicitly says it is not wired into
  startup and is not yet the high-scale evicted-only recovery path.
- Root `mix.exs` still uses `cmd mix test`; this is not the older deprecated
  `cmd --app` form, but it is still a shallow umbrella test alias with no
  profile-specific integration command.

## Conclusion

Chronicle has the skeleton of a practical BPMN-style engine and several key
reliability fixes are already present. It should be described as a BPMN subset
runtime, not as a complete strict BPMN 2.0 engine yet. The next useful milestone
is to make the supported subset explicit, add executable tests for every claimed
node type, and remove or qualify README claims that imply unsupported standard
features.
