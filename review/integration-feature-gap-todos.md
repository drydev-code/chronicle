# Integration Feature Gap TODOs

Date: 2026-04-27

This file tracks integration/platform gaps outside the core BPJS BPMN runtime.
The engine/runtime docs already cover BPMN coverage; this file focuses on
outbound REST, AI/LLM, database execution, auth, executor plugins, and
production integration concerns.

## Current Implementation Snapshot

Implemented today:

- Built-in service-task executor plugin registry via
  `config :server, :service_task_executors, [MyExecutor]`.
- Durable connector registry with seed config, database-backed overrides,
  explicit reload/upsert/delete APIs, connector-id-first routing, and
  placement metadata pass-through from BPJS service-task properties.
- Docker Compose reference satellites split by connector family:
  REST/AI, database, and email/transform, plus a local mock HTTP/AI endpoint.
- Built-in topics:
  - `rest`, `http`, `https`
  - `database`, `db`, `sql`
  - `ai`, `llm`
  - `email`, `mail`
  - `transform`, `echo`, `map`
- REST executor supports endpoint, method, body templating, custom headers,
  timeout, JSON response decoding, HTTP status failure, result mode/path, and
  bearer token injection from direct value or environment variable.
- The reference satellite supports REST auth modes `none`, `bearer`, `basic`,
  `digest`, `api_key`, `oauth2_client_credentials`, AWS SigV4, mTLS/TLS
  options, timeout, retry/backoff, idempotency keys, and sanitized errors.
- The reference satellite includes a provider-neutral AI service layer with
  OpenAI-compatible HTTP defaults, explicit LiteLLM routing, chat, embeddings,
  structured JSON/schema handling, fallback models, retry/rate-limit handling,
  token usage, and cost metadata.
- Database executor runs SQL against `Chronicle.Persistence.Repo.active()` with
  params, timeout, read-only default, optional `allowWrite`, single-statement
  guard, and result shaping.
- The reference satellite supports connector-specific database configs,
  cached connections, SQLite/MySQL/PostgreSQL/MSSQL parameter conventions,
  read/write policies, allowed/denied tables, transaction modes, result modes,
  and stored-procedure calls where the driver supports them.
- Main Chronicle persistence has Ecto repos for MySQL, PostgreSQL, and SQL
  Server, selected by `DB_ADAPTER`. DataBus has the same three adapter families.
- Chronicle/satellite AMQP messages support x509 signing, verification,
  multiple trusted certificates, fingerprint pinning, certificate date
  validation, direction/type requirements, and dev cert wiring in compose.
- Satellites expose `/livez`, `/healthz`, `/readyz`, `/heartbeat`, and
  `/metrics`, and emit JSON lifecycle logs with correlation, task, tenant,
  connector, executor, duration, and sanitized error metadata.
- Example diagrams and smoke tests cover happy-path connector families and
  representative failure paths.
- Transport retry policy is implemented as 5 attempts by default, overridable
  by process definition, with exponential jitter backoff and retry/DLQ queues
  scoped by satellite queue plus connector ID after the transport budget is
  exhausted.
- External connector runtime uses soft lease hints rather than hard expiry.
  Chronicle keeps BPMN business failures, retry timers, and boundary routing in
  workflow state instead of offloading them to RabbitMQ DLQs.

Remaining production validation:

- Server-facing user/API authentication is still intentionally minimal:
  production deployments need API-key/JWT/OIDC auth, route scopes, tenant
  authorization, and audit logging.
- Secret-manager integration is not complete. The connector/satellite code can
  consume env/config values, but Vault/cloud/Kubernetes secret providers and
  rotation workflows are still deployment work.
- Provider certification is not exhaustive. The code paths exist for common
  REST auth, LiteLLM/OpenAI-compatible AI, and common SQL adapters, but each
  target provider/database should still be validated with real credentials,
  network policy, TLS material, and production limits.
- Built-in local database execution remains intentionally conservative. Use the
  database satellite for arbitrary business databases.

## P0: Production Auth And Authorization

Need:

- Replace the `x-user-id` auth plug with real authentication.
- Add route-level authorization policy for admin/destructive routes.
- Define tenant isolation rules for all API endpoints and external task
  completion routes.
- Add tests that unauthenticated callers cannot start instances, complete
  tasks, upload deployments, read telemetry, or terminate instances.
- Add tests that a user from one tenant cannot inspect or mutate another
  tenant's instances, deployments, or tasks.

Implementation notes:

- Candidate first auth modes:
  - Static API keys for simple deployments.
  - JWT bearer validation with issuer/audience/JWKS config.
  - OIDC integration for production users.
- Keep test/local bypass explicit and impossible to enable accidentally in
  production.
- Treat `x-user-id` as a trusted upstream header only when an explicit
  reverse-proxy mode is enabled.

Nice to have:

- Role mapping from JWT claims/groups.
- Per-route scopes such as `workflow:start`, `task:complete`, `admin:deploy`,
  `admin:terminate`, and `telemetry:read`.
- Audit log entries for admin/destructive actions.

## P0: REST Executor Auth Modes

Need:

- Keep the satellite REST auth matrix covered by tests as providers are added.
- Add deployment-specific secret references for credentials instead of inline
  values in production diagrams.
- Add allowlist/denylist policy per satellite/connector to reduce SSRF risk.

Should have:

- Request/response size limits.
- Per-host circuit breakers and rate limits.

Nice to have:

- Cookie/session auth only if there is a concrete user workflow requirement.
- Additional cloud request signing adapters as concrete providers require them.

## P0: AI/LLM Service

Need:

- Certify the AI satellite against the concrete LiteLLM/OpenAI-compatible
  gateways used in production.
- Define persistence/redaction policy per tenant for prompts, outputs, tool
  calls, and provider metadata.
- Add secret-provider backed AI credentials.

Recommended direction:

- Introduce `Chronicle.Server.AI` as a small internal service abstraction.
- Prefer talking to LiteLLM or another OpenAI-compatible gateway for many
  providers instead of embedding every provider SDK in Chronicle.
- Keep direct arbitrary REST available for advanced users.

Should have:

- Model-specific token/size guardrails.
- Per-tenant AI provider configuration.

Nice to have:

- Streaming partial responses if a future UX needs it.
- Embeddings/rerank/image/audio task families as separate explicit topics.
- Prompt/version registry for reproducible workflows.

## P0: Database Service Task Connections

Need:

- Keep arbitrary business DB work on the database satellite rather than the
  local built-in executor.
- Add tenant-scoped authorization checks for connector IDs before dispatch.
- Back database credentials with secret references and rotation.

Should have:

- Connection health checks.
- Pool lifecycle and reload behavior when connector config changes.
- Optional migration/version guard for business schemas.
- Vector-search metadata conventions for embedding provider, model,
  dimensions, metric, index/table name, and source document identifiers.

Nice to have:

- Additional adapters only when demanded:
  - SQLite for embedded/dev workflows.
  - Oracle for enterprise deployments.
  - ClickHouse for analytics.
  - Snowflake/BigQuery/Redshift through dedicated satellites or HTTP drivers.
- A query builder/DSL for simple read tasks to avoid dialect-specific SQL.
- Result pagination/streaming for large result sets.

## P1: SQL Dialect And Query Semantics

Need:

- Document the satellite's per-adapter parameter conventions and raw-SQL
  portability limits.
- Define how identifiers, schemas, limits, date/time, JSON columns, booleans,
  and generated IDs should be represented in cross-dialect workflows.

Recommended direction:

- Keep raw SQL as an expert escape hatch.
- Add simple portable operations for common cases:
  - select one/many
  - insert
  - update
  - upsert
  - execute stored procedure
- Compile those operations per adapter where practical.

Nice to have:

- SQL lint/dry-run endpoint per connection.
- Named query registry to keep SQL out of diagrams.
- Query versioning and approval workflow for write queries.

## P1: Secrets And Connector Configuration

Need:

- Introduce secret references for REST, AI, database, email, and future
  connectors.
- Ensure diagrams cannot accidentally persist plaintext production secrets.
- Support environment-backed secret provider as the first implementation.
- Design an interface that can later support Vault, cloud secret managers, or
  Kubernetes secrets.
- Add config validation at startup and clear runtime errors for missing secret
  references.

Should have:

- Per-tenant connector registry.
- Secret rotation behavior.
- Connector metadata endpoint that exposes safe names/capabilities but never
  secret values.

Nice to have:

- Encrypted-at-rest local secret store for small deployments.
- UI/editor integration that inserts secret references rather than secret
  values.

## P1: Email Delivery

Need:

- Decide whether Chronicle should deliver email or only prepare email command
  payloads.
- If delivering email:
  - add SMTP/provider connector config
  - add retries/backoff
  - add attachment size limits
  - add result shape with provider message ID
  - add tests against a fake SMTP/provider endpoint

Nice to have:

- Provider adapters for SMTP, SendGrid, SES, Graph/M365.
- Template registry for email bodies.

## P1: Executor Reliability

Need:

- Keep transport retry/backoff policy aligned with the documented default:
  max 5 attempts unless overridden by the process definition, exponential
  backoff, and jitter.
- Distinguish deterministic user/config errors from transient infrastructure
  errors.
- Add idempotency keys for side-effecting REST/AI/database/email calls.
- Add telemetry events for executor duration, status, retries, provider, and
  sanitized error class.
- Add bounded concurrency for built-in executors.

Should have:

- Replay runbooks for the implemented per-connector-ID RabbitMQ DLQ queues.
- Monitoring for soft lease hints and missing heartbeats on long-running
  external work.
- Graceful shutdown that does not abandon in-flight built-in tasks.

Nice to have:

- Circuit breakers per connector.
- Bulkhead isolation per connector/provider.

## P2: Developer Experience

Need:

- Keep every built-in and satellite executor property documented with examples.
- Maintain examples for REST auth modes, AI OpenAI-compatible calls, and DB
  connection IDs as connector behavior expands.
- Add generated JSON schema for Chronicle service-task extensions.

Nice to have:

- CLI command to validate a deployment package and connector references.
- Local fake connector server for tests and examples.
- Editor snippets for common task types.
