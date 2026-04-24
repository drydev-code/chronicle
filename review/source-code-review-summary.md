# Chronicle Source Code Review Summary

Date: 2026-04-24

## Scope

Reviewed the full source tree under `apps/`, `config/`, `docker/`, and the root Mix/Docker metadata. After the initial static pass, Docker was used to run Mix and start the service stack.

## Bottom Line

The repository has a coherent architecture for a BPMN workflow engine: an embeddable engine app, a Phoenix/AMQP server wrapper, per-instance GenServers, diagram/DMN stores, an event-store abstraction, external task routing, and an eviction/restore design.

However, several core reliability claims are not currently met. The most important gaps are around event sourcing, persistence, eviction lifecycle durability, version-safe restoration, and unauthenticated operational endpoints. In its current state, the engine may work for happy-path in-memory executions, but it is not yet safe to treat as a durable event-sourced workflow runtime.

## Highest-Risk Findings

1. Active process events are not persisted continuously. Active instances are invisible to startup restore until eviction, and crashes before completion/eviction lose workflow state.

2. Eviction persists the full event history repeatedly with `append_batch`, causing duplicated replay events after multiple eviction cycles.

3. Evicted load cells are started with `start_link/1` from the eviction manager rather than supervised. If that process disappears, evicted instances can lose wake-up routing.

4. Restoring an instance uses the latest process definition instead of the version recorded in the start event.

5. The server routes sensitive APIs without the existing auth plug, including deployment, migration, telemetry, stress testing, and terminate-all endpoints.

6. `.bpmn` files are accepted by deployment and sent to the JSON parser even though the README says XML parsing is not wired.

## Docker Verification Status

Attempted:

```powershell
docker compose build app test
docker compose --profile test run --rm test
docker compose up -d app
Invoke-WebRequest -UseBasicParsing http://localhost:4000/api/management/active-processes-count
Invoke-WebRequest -UseBasicParsing http://localhost:4000/api/telemetry/is-enabled
```

Results:

1. The Docker build compiled the Elixir apps and surfaced compiler warnings, then failed during final `chronicle-app:latest` image export because that image already existed. The already-present image was still usable for startup.

2. `docker compose --profile test run --rm test` completed with exit code `0`, but Mix reported `There are no tests to run`.

3. `docker compose up -d app` successfully started MySQL, RabbitMQ, and the Phoenix app. The app listened on `http://localhost:4000` and connected to AMQP.

4. Startup logs confirmed the migration executes destructive `DROP TABLE IF EXISTS` statements for process-instance tables.

5. Unauthenticated HTTP smoke checks returned `200`: `/api/management/active-processes-count` returned `{"active":0,"hibernating":0}` and `/api/telemetry/is-enabled` returned `false`.

Compiler warnings observed during Docker/Mix:

1. `:xmerl_scan.string/2 is undefined`, making DMN XML evaluation suspect at runtime.

2. `Chronicle.Engine.Instance` references `Chronicle.Server.Host.LargeVariables`, which is undefined when compiling the engine app in isolation.

3. Duplicate telemetry controller function clauses are unreachable.

4. The root `mix test` alias uses deprecated `mix cmd --app`.

## Recommended Fix Order

1. Fix event persistence semantics first: create active rows on start, append or checkpoint on every durable transition, and make append operations idempotent.

2. Supervise load cells and make evicted wake-up routing recoverable from persisted wait handles.

3. Restore by exact process name/version/tenant and add migration-specific behavior separately.

4. Lock down HTTP/API and mock/debug endpoints before exposing the service.

5. Add focused regression tests for persistence, restore, eviction/wakeup, deployment parsing, and unauthenticated API behavior.
