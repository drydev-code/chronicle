# Satellite Observability Notes

Date: 2026-04-27

## Runtime Contract

The Python satellite exposes health, readiness, heartbeat, metrics, and JSON
logs from the same process as the AMQP consumer:

- `/livez` and `/healthz`: process heartbeat state.
- `/readyz`: `200` only while the AMQP consumer is connected and consuming.
- `/heartbeat`: simple monitor-friendly heartbeat payload.
- `/metrics`: Prometheus text metrics with satellite, queue, topic, and
  connector labels.

Readiness intentionally follows AMQP consumer state. During RabbitMQ outages or
consumer restarts, the process can stay live while `/readyz` returns `503`.

## Structured Logs

Task lifecycle logs include:

- `correlation_id`
- `external_task_id`
- `tenant_id`
- `topic`
- `connector_id`
- `executor`
- `duration_ms`
- sanitized exception type/message/stack on failure

The shared redactor strips nested token, secret, password, authorization, and
API key fields before they are written to stdout.

## Retry And Dead Letter Signals

Connector execution failures are published back to Chronicle as
`ServiceTaskFailedEvent` and acknowledged only after the response publish path
runs. Chronicle remains the durable source for retry timers, boundary routing,
and final failure state.

Transport retry policy is intentionally narrower: it covers message delivery
and consumer-side transient failures before Chronicle receives a connector
response. The default max transport retry budget is 5 attempts, overridable by
the process definition with `transport.maxRetries`. Retry delay uses
exponential backoff with jitter.

Task leases are soft. Process definitions may provide lease hints such as
`lease.expectedRuntimeMs`, `lease.heartbeatIntervalMs`, and `lease.warnAfterMs`,
but long-running connectors are not killed merely for exceeding those hints
while they continue to heartbeat.

Monitor these dimensions:

- Satellite metrics: completed/failed/skipped task counters, consumer restarts,
  publish count, execution duration, heartbeat age, and readiness.
- Satellite logs: `satellite_task_failed` grouped by connector/topic/error.
- Broker metrics: queue depth, unroutable messages, and deployment-specific
  dead-letter queues.
- Chronicle workflow events: retry attempts, boundary catches, and terminal
  failed tasks.

Dead-letter queues should be configured as RabbitMQ policies per deployment
when required. Use per-connector-ID DLQs so a failing `rest-main` connector does
not block replay for `database-main` or `ai-main`. Keep the satellite behavior
focused on clear acknowledgements, structured failure publication, and
replay-friendly task identifiers.

## Example Coverage

- `examples/workflows/satellite-connector-family-catalog.bpjs` covers the
  transform, database, REST, AI, and email connector families in one happy-path
  workflow.
- `examples/workflows/satellite-failure-observability.bpjs` models expected
  REST auth, database policy, AI gateway, and email validation failures with
  error boundaries and a normalized transform notice.
- `scripts/smoke_satellite_examples.py` exercises all Python connector
  families locally without AMQP and asserts representative failure paths.
