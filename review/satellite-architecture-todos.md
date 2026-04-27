# Satellite Architecture Status And TODOs

Date: 2026-04-27

This file tracks the satellite connector architecture now merged into `main`.

## Implemented

- Split Python satellites into separate deployable app directories:
  - `satellites/rest-ai`
  - `satellites/database`
  - `satellites/email-transform`
  Shared AMQP, signing, metrics, registry helpers, and executor code live under
  `satellites/shared/python/chronicle_satellite`.
- Docker Compose starts all three satellites plus the local mock connector
  service.
- `SATELLITE_TOPICS` was removed from the Chronicle placement path.
- BPJS service task properties now pass connector and execution metadata
  through the parser and host pipeline.
- The connector registry supports seed config, durable database overrides,
  explicit reload/upsert/delete APIs, connector-id-first matching, topic-family
  matching, placement, capabilities, placement metadata, and execution
  metadata.
- Connector-id-only registry entries are valid, so explicit `connectorId`
  routing does not require broad topic aliases.
- REST satellite support covers no-auth, bearer, basic, digest, API key,
  OAuth2 client credentials, AWS SigV4, mTLS/TLS options, retries/backoff,
  idempotency keys, timeout, result shaping, and sanitized error classes.
- AI satellite support covers OpenAI-compatible HTTP calls, LiteLLM routing,
  chat, embeddings, structured JSON/schema output, fallback models, retry/rate
  limit handling, usage, token, and cost metadata.
- Database satellite support covers connector-specific connection configs,
  connection caching, SQLite/MySQL/PostgreSQL/MSSQL parameter conventions,
  read/write policy, allowed/denied tables, single-statement guards,
  transaction modes, result modes, and stored procedure calls where supported.
- Chronicle and satellites support x509 message signing and verification,
  multiple trusted certs, certificate fingerprint pinning, certificate date
  validation, and direction/type signature requirements.
- Satellites expose `/livez`, `/healthz`, `/readyz`, `/heartbeat`, and
  `/metrics`, and emit structured JSON task lifecycle logs.
- Example diagrams cover happy-path connector families and expected satellite
  failure observability.
- RabbitMQ transport reliability is implemented in the reference satellites:
  default max transport retries is 5, process definitions can override that
  budget, delivery retries use exponential backoff with jitter, and retry/DLQ
  queues are scoped by satellite queue plus connector ID.
- Task runtime uses soft leases with process-configurable hints. Hints drive
  monitoring and warning behavior, while successful heartbeats can continue for
  unlimited connector runtime.
- BPMN failures remain Chronicle state. Connector business failures publish
  `ServiceTaskFailedEvent`; BPMN retry timers, error boundaries, and terminal
  failure handling are not modeled as RabbitMQ DLQ state.

## Remaining P0

- Replace the server-facing `x-user-id` development auth with production auth:
  API keys, JWT/JWKS, or OIDC; route scopes; tenant authorization; and audit
  logging.
- Add tenant-scoped connector authorization before dispatch so a workflow can
  only use connector IDs granted to its tenant.
- Back connector credentials with a real secret-provider interface, starting
  with env/secret references and leaving room for Vault, Kubernetes, and cloud
  secret managers.
- Add operational replay runbooks for the implemented per-connector-ID DLQ
  queues, including how to inspect, drain, requeue, or quarantine messages.
- Add provider certification tests with real deployment credentials for the
  concrete REST providers, LiteLLM/OpenAI-compatible gateways, and databases
  each production environment uses.

## Remaining P1

- Add per-connector health/status to the management API.
- Add connector concurrency limits, circuit breakers, and rate-limit metrics.
- Add outbound host allowlists/denylists per satellite or connector.
- Add cancellation/compensation propagation for connectors that can stop
  in-flight work safely.
- Add explicit envelope version negotiation before promising third-party
  satellite SDK compatibility.

## Remaining P2

- Add HTTP pull/long-poll transport for users who cannot run AMQP.
- Add a third-party satellite conformance test suite.
- Add editor/UI support for selecting connector IDs and secret references.
- Add tooling to scan diagrams for inline secrets and suggest connector IDs.
