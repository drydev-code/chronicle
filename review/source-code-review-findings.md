# Chronicle Source Code Review Findings

Date: 2026-04-24

## Critical / High

### 0. DMN XML evaluation depends on an unavailable `:xmerl_scan` module

Files:

- `apps/engine/lib/chronicle/engine/dmn/dmn_evaluator.ex:33`
- `apps/engine/mix.exs:15`

Docker/Mix compilation emitted `:xmerl_scan.string/2 is undefined (module :xmerl_scan is not available or is yet to be defined)`. The engine app lists only `:logger` and `:runtime_tools` in `extra_applications`, so `:xmerl` is not guaranteed to be available when `DmnEvaluator.evaluate/2` runs.

Impact:

- Rules tasks using DMN XML may fail at runtime even though DMN support is advertised.
- This is a live compiler warning from the Docker build and app startup, not just a static suspicion.

Recommendation:

Add `:xmerl` to the engine application's `extra_applications` or otherwise ensure it is loaded before evaluating DMN content. Add a Docker-backed regression test that evaluates a minimal DMN document.

### 1. Active workflows are not durably event-sourced until completion or eviction

Files:

- `apps/engine/lib/chronicle/engine/instance.ex:134`
- `apps/engine/lib/chronicle/engine/instance.ex:418`
- `apps/engine/lib/chronicle/engine/instance.ex:422`
- `apps/engine/lib/chronicle/persistence/event_store.ex:7`
- `apps/engine/lib/chronicle/persistence/event_store.ex:14`

`Instance` appends persistent events only to `state.persistent_events`. It does not call `EventStore.create/2`, `EventStore.append/2`, or `EventStore.append_batch/2` during normal execution. The only observed persistence paths are completion, termination, and eviction.

Impact:

- A running instance that waits on a message, timer, call, or external task is not present in `ActiveProcessInstances` unless it has been evicted.
- `Chronicle.Supervisor.restore_active_instances/0` only restores rows from `EventStore.list_active_ids/0`, so non-evicted active workflows are lost after a node/VM restart.
- This contradicts the README claim of an append-only event-sourced runtime.

Recommendation:

Persist the `ProcessInstanceStart` event synchronously during instance initialization, then persist durable transition events as they occur. If performance is a concern, introduce explicit snapshots/checkpoints, but make crash recovery semantics clear and tested.

### 2. Re-eviction duplicates the full event history

Files:

- `apps/engine/lib/chronicle/engine/instance_load_cell/lifecycle.ex:176`
- `apps/engine/lib/chronicle/persistence/event_store.ex:67`
- `apps/engine/lib/chronicle/persistence/event_store.ex:76`

`persist_events_sync/1` calls `EventStore.append_batch(instance_state.id, instance_state.persistent_events)`. `append_batch/2` loads the existing JSON event array and appends all supplied events. Because `instance_state.persistent_events` is the full history, not just new events, a second eviction appends the same prefix again.

Impact:

- Event logs grow incorrectly after each eviction cycle.
- Replay may reconstruct invalid or duplicated token/task/timer state.
- Operational storage usage grows faster than the actual workflow history.

Recommendation:

Use sequence numbers or event IDs and append only events not already stored. Alternatively, replace the active row with a full snapshot explicitly named and handled as a snapshot, not as append-only events.

### 3. Evicted load cells are not supervised and wake-up routing is volatile

Files:

- `apps/engine/lib/chronicle/engine/eviction_manager.ex:166`
- `apps/engine/lib/chronicle/engine/instance_load_cell/lifecycle.ex:200`
- `apps/engine/lib/chronicle/engine/instance_load_cell/lifecycle.ex:203`

`InstanceLoadCell.start_link/1` is called from `EvictionManager.try_evict_instance/1`. The cell is linked to the manager process, not started under a supervisor. Evicted wait registrations live in process-local registry entries.

Impact:

- If the load cell or eviction manager crashes/restarts, evicted instances may remain in the database but lose `:evicted_waits` routing.
- External task/message/signal wakeups can be dropped or become unroutable.
- A process crash in a cell can cascade unexpectedly due to linking.

Recommendation:

Add a dedicated `DynamicSupervisor` for load cells. Persist enough waiting-handle metadata to reconstruct evicted routing on restart, or restore evicted instances during startup.

### 4. Restore ignores the persisted process version

Files:

- `apps/engine/lib/chronicle/engine/instance.ex:143`
- `apps/engine/lib/chronicle/engine/instance/event_replayer.ex:32`
- `apps/engine/lib/chronicle/engine/diagrams/diagram_store.ex:24`

`ProcessInstanceStart` records `process_version`, but `EventReplayer.restore_from_events/2` calls `DiagramStore.get_latest(process_name, tenant_id)`.

Impact:

- A workflow started under version `1` can resume under version `2` after a deploy.
- Token node IDs and paths may not exist or may mean something different.
- This makes restore behavior non-deterministic across deployments.

Recommendation:

Restore with `DiagramStore.get(process_name, start_event.process_version, tenant_id)`. Treat migration to latest as an explicit migration operation, not as default replay behavior.

### 5. Sensitive HTTP endpoints are unauthenticated

Files:

- `apps/server/lib/chronicle/server/web/router.ex:7`
- `apps/server/lib/chronicle/server/web/router.ex:13`
- `apps/server/lib/chronicle/server/web/plugs/auth.ex:1`
- `apps/server/lib/chronicle/server/web/controllers/deployment_controller.ex:28`
- `apps/server/lib/chronicle/server/web/controllers/management_controller.ex:56`
- `apps/server/lib/chronicle/server/web/controllers/process_instance_controller.ex:69`

The router pipeline includes tenant extraction but does not use `Chronicle.Server.Web.Plugs.Auth`. Operational endpoints can start workflows, migrate workflows, deploy content, read local files via the mock deployment endpoint, run stress tests, inspect telemetry, and terminate all instances.

Docker smoke-test evidence:

- `GET http://localhost:4000/api/management/active-processes-count` returned `200` with `{"active":0,"hibernating":0}` and no auth headers.
- `GET http://localhost:4000/api/telemetry/is-enabled` returned `200` with `false` and no auth headers.

Impact:

- Anyone with network access to the service can perform destructive workflow operations.
- `deploy_mock` can read arbitrary server-local paths accepted by `File.read/1`.
- `stress_test` can spawn unbounded tasks/instances from a request parameter.

Recommendation:

Require authentication and authorization for all write/management endpoints. Remove `deploy_mock` from production builds or guard it behind dev/test config. Add request validation and hard caps for stress testing.

### 6. `.bpmn` uploads are accepted but parsed as JSON

Files:

- `README.md:40`
- `apps/server/lib/chronicle/server/host/deployment/manager.ex:24`
- `apps/server/lib/chronicle/server/host/deployment/manager.ex:56`

The README says `.bpmn` XML parsing is not wired. The deployment manager still accepts `.bpmn` files as `:bpmn` and sends their content to `Chronicle.Engine.Diagrams.Parser.parse/1`, which expects JSON/BPJS.

Impact:

- Valid BPMN XML uploads fail with JSON parse errors.
- The API behavior conflicts with documented limitations.
- ZIPs containing `.bpmn` files are silently routed to the wrong parser.

Recommendation:

Either reject `.bpmn` with a clear `:xml_bpmn_not_supported` error, or wire in a real XML BPMN parser. Until XML is supported, only accept `.bpjs` for executable process definitions.

## Medium

### 7. Diagram duplicate-ID validation cannot work after parsing

Files:

- `apps/engine/lib/chronicle/engine/diagrams/parser.ex:95`
- `apps/engine/lib/chronicle/engine/diagrams/sanitizer.ex:18`

The parser uses `Enum.into(nodes_data, %{}, ...)`, so duplicate node IDs overwrite earlier nodes before `Sanitizer.check_unique_node_ids/2` runs. By the time the sanitizer sees `definition.nodes`, duplicates have already been lost.

Impact:

- Invalid diagrams can pass validation after silently dropping nodes.
- Connections may point to overwritten or missing nodes.

Recommendation:

Validate duplicate IDs on the raw node list before converting to a map, or make the parser return an error when encountering duplicates.

### 8. Wait registry entries are never unregistered for resident instances

Files:

- `apps/engine/lib/chronicle/engine/token_processor.ex:219`
- `apps/engine/lib/chronicle/engine/token_processor.ex:229`
- `apps/engine/lib/chronicle/engine/instance/wait_registry.ex:16`
- `apps/engine/lib/chronicle/engine/instance/wait_registry.ex:37`

Message and signal waits are registered in `:waits`, but the resident wait handling removes only in-memory maps. Registry entries remain until the process exits.

Impact:

- Old message/signal wait registrations accumulate.
- Repeated correlations dispatch unnecessary messages to instances that are no longer waiting.
- Long-lived workflow instances can develop increasingly noisy routing behavior.

Recommendation:

Call `Registry.unregister_match/3` or equivalent cleanup when a wait is consumed, cancelled, interrupted, or the token terminates.

### 9. Timer events are not appended when timers fire

Files:

- `apps/engine/lib/chronicle/engine/token_processor.ex:199`
- `apps/engine/lib/chronicle/engine/instance.ex:350`
- `apps/engine/lib/chronicle/engine/instance/wait_registry.ex:104`
- `apps/engine/lib/chronicle/engine/persistent_data.ex:40`

The code defines `TimerElapsed` persistent data and appends `TimerCreated`, but `handle_info({:timer_elapsed, ...})` only resumes the token. It does not append a `TimerElapsed` event.

Impact:

- If state is persisted after a timer fires, replay may still see an open timer and schedule it again.
- Timer replay semantics are incomplete compared with the persistent data model.

Recommendation:

Append `TimerElapsed` when a timer resumes a token, including enough target-node/retry metadata for deterministic replay.

### 10. Completion and termination persistence runs asynchronously and errors are ignored

Files:

- `apps/engine/lib/chronicle/engine/instance.ex:422`
- `apps/engine/lib/chronicle/engine/instance.ex:430`

`persist_completion/1` and `persist_termination/2` run in fire-and-forget tasks. The instance transitions and publishes completion/termination events without waiting for the database transaction to succeed.

Impact:

- A process can report completion even if persistence fails.
- DB failures are not surfaced to callers or supervision.
- Completed/terminated history can be missing.

Recommendation:

Perform terminal persistence in the instance process or a monitored durable writer and only publish terminal lifecycle events after success. At minimum, log and retry failures.

### 11. The engine app directly references the server app

Files:

- `apps/engine/lib/chronicle/engine/instance.ex:407`
- `apps/engine/lib/chronicle/engine/instance.ex:411`
- `apps/engine/mix.exs`

Docker/Mix compilation emitted warnings that `Chronicle.Server.Host.LargeVariables.enabled?/0` and `cleanup/2` are undefined while compiling `engine`. The `engine` app is advertised as an embeddable library, but it directly references a module from the `server` app without declaring a dependency.

Impact:

- Embedding `:engine` without `:server` can crash when an instance completes.
- The app boundary described in the README is violated.
- Compiler warnings are already present in Docker builds.

Recommendation:

Move large-variable cleanup behind an engine-owned behaviour/config callback, or make cleanup a host-level subscriber to engine completion events.

### 12. Deployment and diagram stores are in-memory only

Files:

- `apps/engine/lib/chronicle/engine/diagrams/diagram_store.ex:15`
- `apps/server/lib/chronicle/server/host/deployment/manager.ex:75`

Process definitions and DMNs are registered in ETS/GenServer memory only. There is no persistent deployment store in this source tree.

Impact:

- Restarting the service drops all deployed definitions.
- Active instance restore can fail because `EventReplayer` cannot find the definition after restart unless definitions are redeployed first.

Recommendation:

Persist deployment packages/compiled definitions or load them from a configured deployment source before restoring active instances.

### 13. Migration runner swallows migration errors

Files:

- `apps/engine/lib/chronicle/supervisor.ex:118`
- `apps/engine/lib/chronicle/supervisor.ex:132`

`run_migrations/0` rescues all errors and logs a warning that the migration may already be applied.

Impact:

- Real schema problems can be hidden while the app continues booting into a broken runtime.
- Later failures become harder to diagnose.

Recommendation:

Only tolerate known idempotency errors if needed. Otherwise fail fast on migration errors, especially in production.

## Lower-Severity / Maintainability

### 14. The migration drops existing process-instance tables

Files:

- `apps/engine/priv/repo/migrations/20260310000002_create_process_instance_tables.exs:6`
- `apps/engine/priv/repo/migrations/20260310000002_create_process_instance_tables.exs:7`
- `apps/engine/priv/repo/migrations/20260310000002_create_process_instance_tables.exs:8`

The migration explicitly drops existing `.NET`-style tables before recreating them.

Docker startup evidence:

- App logs showed `execute "DROP TABLE IF EXISTS \`ActiveProcessInstances\`"`.
- App logs showed `execute "DROP TABLE IF EXISTS \`CompletedProcessInstances\`"`.
- App logs showed `execute "DROP TABLE IF EXISTS \`TerminatedProcessInstances\`"`.

Impact:

- Running migrations against a database with production data can delete active/completed/terminated workflow history.

Recommendation:

Replace destructive drops with additive migrations or explicit one-time migration tooling that backs up and transforms existing data.

### 15. Telemetry controller duplicates function definitions

Files:

- `apps/server/lib/chronicle/server/web/controllers/telemetry_controller.ex:39`
- `apps/server/lib/chronicle/server/web/controllers/telemetry_controller.ex:47`
- `apps/server/lib/chronicle/server/web/controllers/telemetry_controller.ex:113`
- `apps/server/lib/chronicle/server/web/controllers/telemetry_controller.ex:121`

The DB telemetry endpoints are defined twice with identical names/arities. Docker/Mix compilation also reported the later clauses cannot match because earlier clauses always match.

Impact:

- Compiler warnings and confusing maintenance surface.
- Future changes can accidentally update only one copy.

Recommendation:

Delete the duplicated block.

### 16. Request parameter parsing can crash controllers

Files:

- `apps/server/lib/chronicle/server/web/controllers/process_instance_controller.ex:67`
- `apps/server/lib/chronicle/server/web/controllers/process_instance_controller.ex:70`
- `apps/server/lib/chronicle/server/web/controllers/telemetry_controller.ex:40`

Several endpoints call `String.to_integer/1` directly on request data.

Impact:

- Malformed input raises instead of returning `400`.
- Large counts/limits can stress the service.

Recommendation:

Use safe parsing helpers, validate ranges, and return structured `400` errors.

### 17. Root Mix test alias uses deprecated `mix cmd --app`

Files:

- `mix.exs:16`

Docker test output warned that `--app` in `mix cmd` is deprecated and recommends `mix do --app` instead.

Impact:

- The test command still runs today, but future Mix versions may remove this path.

Recommendation:

Update the alias to the current Mix syntax.
