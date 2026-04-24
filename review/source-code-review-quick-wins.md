# Chronicle Review Quick Wins

Date: 2026-04-24

## Quick Fixes

1. Reject `.bpmn` uploads until XML parsing exists. Keep `.bpjs` as the executable diagram format.

2. Remove or config-gate `POST /api/deployment/mock`; it reads arbitrary local paths.

3. Add `Chronicle.Server.Web.Plugs.Auth` to the router and split public, authenticated, and admin pipelines.

4. Add upper bounds and safe integer parsing for `stress_test`, telemetry `limit`, and migration node mappings.

5. Delete duplicated DB endpoint definitions in `TelemetryController`.

6. Fail fast on migration errors instead of rescuing all exceptions.

7. Validate duplicate node IDs before converting parser nodes into a map.

8. Unregister consumed message/signal waits from `:waits`.

9. Check `System.find_executable("node")` in `ScriptWorker.init/1` and return a clear startup error if Node.js is missing.

10. Add exact-version restoration via `DiagramStore.get(name, version, tenant)`.

11. Add `:xmerl` to `engine` runtime applications or otherwise load it before DMN evaluation.

12. Remove the `engine -> server` module reference for `LargeVariables`; use a callback or PubSub subscriber instead.

13. Update the root test alias away from deprecated `mix cmd --app`.

## Tests To Add First

1. Starting an instance creates an active event-store row containing `ProcessInstanceStart`.

2. Waiting on an external task/message/timer persists enough state to restore after process restart.

3. Evict, restore, and evict again does not duplicate persisted events.

4. Restoring an instance uses the version from `ProcessInstanceStart`, not the latest definition.

5. Message/signal wait registry entries are removed after consumption.

6. `.bpmn` upload returns a clear unsupported-format error.

7. Auth is required for deployment, migration, telemetry, stress-test, and terminate-all endpoints.

8. Invalid integer query/body values return `400` instead of crashing.

9. A minimal DMN XML document evaluates successfully inside the Docker image.

10. The `engine` app compiles without references to modules owned by `server`.

## Suggested Report-To-Issue Mapping

- Issue 1: Make event persistence actually append-only and crash-safe.
- Issue 2: Supervise and recover evicted load cells.
- Issue 3: Restore workflows by exact definition version.
- Issue 4: Secure management and deployment APIs.
- Issue 5: Align deployment format support with documentation.
- Issue 6: Add minimum regression test suite for persistence and API boundaries.
