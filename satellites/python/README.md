# Chronicle Python Satellites

This directory now exposes a reusable `chronicle_satellite` package plus a few focused entrypoints:

- `python -m chronicle_satellite.entrypoints.all` keeps the previous all-in-one behavior.
- `python -m chronicle_satellite.entrypoints.rest_ai` handles `rest,http,https,ai,llm` and imports `requests`.
- `python -m chronicle_satellite.entrypoints.database` handles `database,db,sql` and imports DB drivers.
- `python -m chronicle_satellite.entrypoints.email_transform` handles `email,mail,transform,echo,map` with only lightweight executor code.

Each entrypoint owns its built-in topic family. Use `SATELLITE_CONNECTOR_IDS` to restrict a running satellite to specific connector IDs from BPJS task properties or the Chronicle connector registry. `SATELLITE_QUEUE`, `SATELLITE_PREFETCH`, and the RabbitMQ environment variables keep their existing behavior. The all-in-one launcher still defaults to `Chronicle.Satellite`; specialized launchers default to distinct queues so they can run side by side.

Set `CHRONICLE_MESSAGE_SIGNING=true` with `CHRONICLE_SIGNER_KEY` / `CHRONICLE_SIGNING_KEY`, `CHRONICLE_SIGNER_CERT` / `CHRONICLE_SIGNING_CERT`, and comma-separated `CHRONICLE_TRUSTED_CERTS` to sign outgoing AMQP payloads and verify Chronicle requests using X.509 certificates. `CHRONICLE_TRUSTED_CERT_FINGERPRINTS` pins accepted signer certificates by SHA-256 fingerprint, and certificate validity dates are checked by default. Require signatures globally with `CHRONICLE_REQUIRE_SIGNATURES=true`, or selectively with `CHRONICLE_REQUIRE_SIGNATURE_MESSAGE_TYPES` and `CHRONICLE_REQUIRE_SIGNATURE_DIRECTIONS`.

The original `requirements.txt` remains the full dependency set. Use `requirements-rest-ai.txt`, `requirements-database.txt`, or `requirements-email-transform.txt` when building narrower satellite images.

## Health, Readiness, And Metrics

Each entrypoint starts a lightweight HTTP observability server in the satellite
process. It has no extra dependency and is intended for Docker Compose and
Kubernetes probes.

Environment:

- `SATELLITE_OBSERVABILITY_ENABLED=true` enables the probe server.
- `SATELLITE_OBSERVABILITY_HOST=0.0.0.0` sets the bind address.
- `SATELLITE_OBSERVABILITY_PORT=8090` sets the probe and metrics port.
- `SATELLITE_HEARTBEAT_INTERVAL_SECONDS=10` controls the in-process heartbeat.

Endpoints:

- `GET /livez` and `GET /healthz` return process heartbeat state.
- `GET /readyz` returns `200` only after the AMQP connection, topology, QoS,
  and consumer have been established; it returns `503` while reconnecting.
- `GET /heartbeat` returns the same heartbeat payload for simple monitors.
- `GET /metrics` exposes Prometheus text metrics for readiness, uptime,
  heartbeat age, delivered/skipped/completed/failed tasks, published events,
  consumer restarts, and execution duration.

The Docker image includes a `HEALTHCHECK` that probes `/readyz` on the
configured observability port. For Kubernetes, use `/livez` as the liveness
probe, `/readyz` as readiness, and scrape `/metrics`.

Logs are JSON lines on stdout. Task logs include `correlation_id`,
`external_task_id`, `tenant_id`, `topic`, and `connector_id`; sensitive fields
such as tokens, passwords, API keys, secrets, and authorization headers are
redacted before logging.

## Retry And Dead-Letter Observability

The reference satellite acknowledges a request only after it publishes the
Chronicle success or failure response for that task. Connector failures become
`ServiceTaskFailedEvent` responses, so retry and boundary behavior remains
owned by Chronicle's durable workflow state instead of a local worker cache.

Transport retries are limited to delivery failures before Chronicle receives a
connector response. The default max transport retry budget is 5 attempts and a
process definition can override it with `transport.maxRetries`. Retry delays
use exponential backoff with jitter by default. Keep this separate from REST or
AI provider retries inside a connector, and separate from BPMN `errorBehaviour:
"retry"` timers persisted by Chronicle.

Task leases are soft progress hints, not hard execution timeouts. A process can
set `lease.expectedRuntimeMs`, `lease.heartbeatIntervalMs`, and
`lease.warnAfterMs` to guide monitoring and autoscaling, while the satellite may
continue running indefinitely when the connector is still alive and
heartbeating.

Operationally, watch these signals together:

- `chronicle_satellite_failed_tasks_total` and `satellite_task_failed` logs for
  connector and validation failures.
- `chronicle_satellite_consumer_restarts_total`, `/readyz`, and
  `heartbeatAgeSeconds` for RabbitMQ/network interruptions.
- RabbitMQ queue depth and any broker-level dead-letter queues for messages
  that cannot be routed or are rejected before reaching the satellite.

If you add broker dead-lettering for a deployment, keep it broker-scoped and
document the queue policy alongside the connector registry. Prefer one DLQ per
connector ID, for example `Chronicle.DLQ.rest-main` and
`Chronicle.DLQ.database-main`, so replay can be paused or drained without
mixing unrelated providers. The satellite logs the task/correlation/connector
IDs needed to replay or quarantine failed work without exposing credentials.

## Local Smoke

Run the reusable smoke harness to validate the example connector diagrams and
exercise every Python connector family without RabbitMQ:

```bash
python scripts/smoke_satellite_examples.py
```

The script starts the local mock HTTP/AI service in-process, uses SQLite for
database coverage, checks transform/email/REST/AI/database success paths, and
asserts expected REST, database, and email failure observations.

## AI connector tasks

`topic: "ai"` and `topic: "llm"` use the AI service layer. The default path remains OpenAI-compatible HTTP when an `endpoint` is present, so existing chat-completion tasks keep working. Set `extensions.provider: "litellm"` or `CHRONICLE_AI_PROVIDER=litellm` to route through LiteLLM when the optional `requirements-ai.txt` dependencies are installed.

Useful AI extensions:

- `model`, `models`, `fallbackModels`, or `modelFallbacks`: primary model and ordered fallback list.
- `operation: "chat"` or `operation: "embeddings"`: selects chat completions or embeddings.
- `prompt`, `messages`, `input`, or `body`: builds the provider request body with Chronicle variable templating.
- `schema`, `jsonSchema`, or `responseSchema`: requests structured JSON where supported and validates the returned JSON before publishing success.
- `providerConfig`: provider-specific settings such as `apiKey`, `apiBase`, `baseUrl`, `organization`, or LiteLLM-specific keyword arguments.
- `maxRetries`, `retryDelayMs`, or REST `retry`: retries rate limits, timeouts, and transient upstream failures.
- `resultPath`: selects from normalized output such as `text`, `json.someField`, `embeddings.0`, `usage`, or `raw`.

When providers return usage, the satellite includes token metadata under the execution result metadata, and cost metadata when the provider reports it.

For embedding and vector-search workflows, include enough metadata with the
result to make later searches reproducible: provider, model, dimensions,
metric, index/table name, and source document identifiers. The AI task can
produce the embedding while a database/vector connector stores or queries it.

## REST connector hardening options

The REST/AI satellite keeps the original `endpoint`, `method`, `body`, `extensions.headers`, `extensions.timeoutMs`, and `extensions.auth` behavior. REST tasks can additionally set:

- `extensions.auth.type`: `none`, `bearer`, `basic`, `digest`, `api_key`, `oauth2_client_credentials`, or `aws_sigv4`. OAuth client-credentials tokens are cached until shortly before expiry. AWS SigV4 uses the built-in signer and accepts `accessKeyId`, `secretAccessKey`, `sessionToken`, `region`, and `service`, with standard `AWS_*` environment fallbacks.
- `extensions.tls` / `extensions.mtls`: pass `verify` or a CA path, plus `clientCert` and optional `clientKey` for mTLS.
- `extensions.timeout`: `{ "connectMs": 1000, "readMs": 5000 }` for separate connect/read timeouts. `timeoutMs` remains supported.
- `extensions.retry`: `{ "maxAttempts": 3, "statuses": [429, 500, 502, 503, 504], "backoffMs": 250, "maxBackoffMs": 5000 }`. Unsafe methods such as `POST` retry only when `extensions.idempotencyKey` is set, unless `retryUnsafe` is explicitly true.
- `extensions.idempotencyKey`: static or templated value for the `Idempotency-Key` header; `true` generates a UUID.

HTTP failures raise categorized `RestConnectorError` values (`auth`, `rate_limited`, `timeout`, `conflict`, `validation`, `upstream`, or `http_status`) with redacted response context for Chronicle failure events.

## Database Provider Configuration

Database connector configuration is provider-specific. Use
`SATELLITE_DB_CONNECTIONS` for a JSON object keyed by connection ID, or
`SATELLITE_DB_CONNECTION_<ID>` for a single override. Supported adapter names
include `sqlite`, `mysql`, `postgres`, and `mssql`, with aliases such as
`postgresql`, `pg`, `mariadb`, `sqlserver`, and `sql_server`.

Useful connection fields include `adapter`, `host`, `port`, `database`,
`username`, `password`, `readOnly`, `allowWrite`, `allowedTables`,
`deniedTables`, `transactionMode`, and `pool`. Workflow tasks select a config
with `extensions.connectionId`; if omitted, the `connectorId` is used, then
`default`.

Keep arbitrary business database access on the database satellite rather than
the built-in local executor. The local executor is intentionally conservative
and should stay limited to Chronicle-owned persistence or tightly controlled
deployment use cases.
