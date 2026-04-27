# Chronicle

BPJS-backed BPMN subset workflow engine for Elixir/OTP. Event-sourced,
actor-based, with DMN decision tables and embedded JavaScript scripting.

## What's in this repo

Umbrella monorepo with two apps:

| App      | Kind    | Role                                                              |
| -------- | ------- | ----------------------------------------------------------------- |
| `engine` | library | BPMN runtime, DMN evaluator, persistence, scripting. No auto-start. |
| `server` | service | Standalone Phoenix REST API, AMQP messaging, external task routing. |

Depend on `:engine` directly (Hex or path) to embed the engine into your
supervision tree. Run `:server` when you want a batteries-included service.

## Features

- **BPJS BPMN subset semantics**: start/end events, intermediate catch/throw,
  gateways (exclusive, parallel, inclusive, event-based), first-class send,
  receive, and manual tasks, lane-based actor routing metadata, and supported
  boundary, loop, and compensation events.
- **Token-based execution** on a per-instance `GenServer` with event-sourcing
  semantics (append-only log, replay on restart). Commands append durable
  events before publishing effects or mutating query-facing projections.
- **Script tasks** — JavaScript via pooled Node.js workers (Jint-compatible
  script API).
- **Rules tasks** — DMN 1.3 decision tables.
- **Call activities** — sync/async child processes with sequential collection
  loops.
- **External tasks** — service and user task fan-out via AMQP, plus built-in
  execution for common service-task topics.
- **Process versioning** with `collection@version!tenant/name`.
- **Multi-tenancy** — registry keyed by `{tenant, instance_id}`.
- **Multi-DB** — MySQL, PostgreSQL, MS SQL Server adapters (runtime select).
- **Eviction manager** — idle-process hibernation for high-scale deployments.

## Diagram formats

The engine executes BPJS JSON diagrams and intentionally does not parse native
BPMN XML in this release:

- `.bpjs` — JSON diagram format (accepts PascalCase and camelCase keys).
- Chronicle JSON: top-level `Name` / `Version` / `Resources` /
  `Processes` diagrams are accepted for the supported Chronicle subset.
- `.bpmn`: rejected with an unsupported-format error; XML parsing is out of scope for this release.

Supported BPJS node types are declared in
`Chronicle.Engine.Diagrams.SupportedFeatures`. Lane metadata is supported only
for resolving `actorType` on service/user task publications. Unsupported BPMN
features such as collaborations, pools, participants, message flows,
event/transaction subprocesses, complex gateways, cancel/multiple events, and
standard multi-instance loop characteristics fail during parsing instead of
silently falling through. `SubProcess` nodes are treated as call activities to
separate processes, not as embedded BPMN subprocess scopes.

Event-based gateways are limited to supported message, signal, receive-task,
and timer branches; unsupported outgoing branches are rejected. Intermediate
conditional catches can park as durable waits and be explicitly re-triggered
through the instance API when variables change. Conditional start events are
evaluated from a variable payload and persist the selected `start_node_id` on
the resulting `ProcessInstanceStart`.

Boundary message, signal, and timer waits are supported for the current
wait-capable activity subset with durable create/cancel/trigger replay.
Retry waits remain interruptible by message, signal, and timer boundaries; an
interrupting boundary durably cancels the retry timer before the boundary path
continues. Non-interrupting message and signal boundaries remain registered
while the activity wait stays open. Non-interrupting timer boundaries are
one-shot: after the timer triggers and creates its boundary token, that timer
registration is closed and replay does not restore it. Conditional boundaries
are evaluated only after durable variable updates persist; non-interrupting
conditional boundaries are one-shot. Compensation boundaries register handlers
for completed compensatable activities; compensation throw/end events request
and start eligible handlers durably. Unsupported boundary features still
include cancel, multiple, and parallel-multiple boundary events.

Standard activity loops use post-test semantics by default: the activity runs
once, then Chronicle evaluates the loop condition with a max-iteration guard
and records the decision as durable loop data. Sequential and parallel
multi-instance characteristics remain out of scope.

Diagram files are shipped inside ZIP deployment packages alongside
`.dmn` decision tables.

## Service and user task execution

Service tasks remain durable external tasks, but the server can now execute
common service topics without a separate AMQP worker. Built-in executors are
registered as plugins under `Chronicle.Server.Host.ExternalTasks.Executors`,
and the list can be replaced with `config :server, :service_task_executors,
[MyExecutor]`.

Production deployments can route service tasks to connector satellites through
the connector registry. The BPJS/Peak service-task handler remains the
`topic` property (`rest`, `database`, `ai`, and so on); `connectorId` selects
the registered connector implementation:

```bash
CONNECTOR_REGISTRY_JSON='{"connectors":[{"id":"rest-main","topics":["rest"],"placement":"satellite"}]}'
```

Satellites consume the same durable AMQP
`ServiceTaskExecutionRequestedEvent` messages that external workers use and
publish existing `ServiceTaskExecutedEvent` / `ServiceTaskFailedEvent`
responses back to Chronicle. This keeps the engine event-sourcing contract
unchanged while moving secrets, network access, and connector dependencies out
of the main server. The Docker Compose stack includes:

- `satellite-rest-ai`: Python reference satellite for REST and AI connectors.
- `satellite-database`: Python reference satellite for database connectors.
- `satellite-email-transform`: Python reference satellite for email and
  transform connectors.
- `satellite-mock`: local HTTP/AI test endpoint used by satellite examples.

Transport retries are broker/consumer delivery retries, not BPMN activity
failures. Chronicle's default transport retry budget is 5 attempts and process
definitions may override it with `transport.maxRetries`. Transport retries use
exponential backoff with jitter so reconnect storms do not synchronize across
satellites. After the transport budget is exhausted, deployments should route
the message to a RabbitMQ dead-letter queue scoped by connector ID, such as
`Chronicle.DLQ.rest-main` or `Chronicle.DLQ.database-main`, so replay and
quarantine can be managed per connector.

Long-running connector work uses a soft lease model. A process definition can
publish lease hints such as `lease.expectedRuntimeMs`,
`lease.heartbeatIntervalMs`, and `lease.warnAfterMs`, but Chronicle does not
impose a hard runtime cap from those hints. A satellite may heartbeat for as
long as the connector is still making progress. Business failures, BPMN retry
timers, and boundary routing remain `ServiceTaskFailedEvent` state inside
Chronicle rather than RabbitMQ dead-letter state.

Chronicle and the Python satellites can sign AMQP payloads with RSA-SHA256 and
verify them against trusted X.509 certificates. The compose stack enables this
for the reference satellites with development-only certificates in
`config/certs`. Production deployments should configure distinct signer and
trust material:

- Chronicle server: `AMQP_SIGNING_ENABLED=true`,
  `AMQP_SIGNER_PRIVATE_KEY_PATH` or legacy `AMQP_SIGNING_PRIVATE_KEY_PATH`,
  `AMQP_SIGNER_CERTIFICATE_PATH` or legacy
  `AMQP_SIGNING_CERTIFICATE_PATH`, and comma-separated
  `AMQP_TRUSTED_CERTIFICATE_PATHS`.
- Python satellites: `CHRONICLE_MESSAGE_SIGNING=true`,
  `CHRONICLE_SIGNER_KEY` or legacy `CHRONICLE_SIGNING_KEY`,
  `CHRONICLE_SIGNER_CERT` or legacy `CHRONICLE_SIGNING_CERT`, and
  comma-separated `CHRONICLE_TRUSTED_CERTS`.
- Pin accepted signer certificates with
  `AMQP_TRUSTED_CERTIFICATE_FINGERPRINTS` or
  `CHRONICLE_TRUSTED_CERT_FINGERPRINTS` using SHA-256 certificate
  fingerprints. Certificate validity dates are checked by default and warn
  when expiry is within 30 days.
- Require signatures globally with `AMQP_REQUIRE_SIGNATURES` /
  `CHRONICLE_REQUIRE_SIGNATURES`, or selectively with
  `AMQP_REQUIRE_SIGNATURE_MESSAGE_TYPES`,
  `AMQP_REQUIRE_SIGNATURE_DIRECTIONS`,
  `CHRONICLE_REQUIRE_SIGNATURE_MESSAGE_TYPES`, and
  `CHRONICLE_REQUIRE_SIGNATURE_DIRECTIONS`.

The Python satellites expose `/livez`, `/readyz`, `/heartbeat`, and
Prometheus-style `/metrics` on `SATELLITE_OBSERVABILITY_PORT` (default `8090`).
Logs are JSON lines with correlation, task, tenant, topic, and connector IDs.
For local connector coverage without RabbitMQ, run:

```bash
python scripts/smoke_satellite_examples.py
```

Chronicle service extensions use the `Chronicle.*` prefix.

- `topic: "rest"`, `"http"`, or `"https"` performs an outbound HTTP request
  from the task `endpoint`, `method`, `body`, and optional
  `extensions.headers` / `extensions.timeoutMs`. The reference satellite also
  supports `extensions.auth` with `none`, `bearer`, `basic`, `api_key`, and
  `oauth2_client_credentials`.
- `topic: "database"`, `"db"`, or `"sql"` runs `extensions.query` against the
  configured Chronicle repo with optional `extensions.params` when executed
  locally. In the reference satellite, `extensions.connectionId` selects a
  configured satellite database connection. Satellite database connections are
  provider-specific and may declare `adapter` (`sqlite`, `mysql`, `postgres`,
  or `mssql`), host/port/database credentials, read/write policy, table
  allowlists or denylists, transaction mode, and result mode. SQL tasks are
  read-only by default; set `extensions.allowWrite: true` only for approved
  write connectors. For vector search workflows, keep embedding/provider
  metadata such as `embeddingModel`, `embeddingProvider`, `vectorDimensions`,
  and `metric` with the database/vector connector result so later searches know
  which index and model family produced the vectors.
- `topic: "ai"` or `"llm"` is treated as a REST-backed AI call and requires an
  `endpoint`; the reference satellite normalizes OpenAI-compatible chat
  responses into `text`, `raw`, `usage`, `model`, and `finishReason`.
- `topic: "email"` or `"mail"` validates and normalizes an email command
  payload.
- `topic: "transform"`, `"echo"`, or `"map"` renders a local template/JSON
  payload without leaving Chronicle.

Other topics are still published as `ServiceTaskExecutionRequestedEvent` for
external workers. Human tasks are not executed by the engine; complete or
reject them through the REST command endpoints:

- `POST /api/user-tasks/:task_id/execute`
- `POST /api/user-tasks/:task_id/reject`

Generic service task command endpoints are also available:

- `POST /api/external-tasks/:task_id/complete`
- `POST /api/external-tasks/:task_id/fail`
- `POST /api/external-tasks/:task_id/cancel`

Chronicle-format parser compatibility can be checked with:

```bash
CHRONICLE_TEST_DIAGRAMS=/path/to/diagrams \
  mix run --no-start ../../scripts/parse_chronicle_diagrams.exs
```

## Quick start (docker)

```bash
git clone <repo> chronicle
cd chronicle
docker compose up --build
```

This starts:

| Service   | Host port | Purpose                         |
| --------- | --------- | ------------------------------- |
| app       | `4000`    | HTTP REST + LiveDashboard       |
| mysql     | `33060`   | Primary store + databus         |
| rabbitmq  | `56720`   | AMQP — external task fan-out    |
| rabbitmq  | `15673`   | Management UI (guest/guest)     |

Run the integration suite against the same stack:

```bash
docker compose --profile test run --rm test
```

## Local dev (without Docker)

Requirements: Elixir 1.17+, Erlang/OTP 26+, Node.js 18+, MySQL 8.

```bash
mix deps.get
mix ecto.setup
mix phx.server
```

## Configuration

All runtime configuration via environment variables. See
[`config/runtime.exs`](config/runtime.exs) for the full list.

Key variables:

```
DB_ADAPTER     mysql | postgres | mssql     (default: mysql)
DB_HOST        database host
DB_USER        database user
DB_PASS        database password
DB_NAME        database name
DB_PORT        database port (optional)
DB_POOL_SIZE   pool size (default: 20)

RABBITMQ_HOST  amqp broker host
RABBITMQ_PORT  amqp port (default: 5672)
RABBITMQ_USER  amqp user (default: guest)
RABBITMQ_PASS  amqp password (default: guest)

EVICTION_ENABLED    true | false (default: false)
EVICTION_IDLE_MS    idle threshold ms (default: 300000)
EVICTION_SCAN_MS    scan interval ms (default: 60000)
EVICTION_MAX_RESIDENT  cap on resident instances (default: unlimited)

SECRET_KEY_BASE   Phoenix secret (required in prod)
PORT              HTTP port (default: 4000)
```

## Embedding the engine as a library

The `engine` app is a pure library — it ships no `Application` callback and
does not start a supervision tree on its own. Mount it into your host app:

```elixir
# mix.exs
def deps do
  [{:engine, "~> 0.1"}]  # or path/in_umbrella during development
end

# lib/my_app/application.ex
def start(_type, _args) do
  children = [
    {Chronicle, []},
    # ... your own children
  ]

  Supervisor.start_link(children, strategy: :rest_for_one)
end
```

`{Chronicle, opts}` accepts:

- `:run_migrations` — run Ecto migrations on startup (default: `true`)
- `:restore_instances` — replay active instances from the event store (default: `true`)

If you prefer a flat child list, use `Chronicle.children(opts)` and
concat into your own supervisor's children.

The `server` app is the canonical example — see
[`apps/server/lib/chronicle/server/application.ex`](apps/server/lib/chronicle/server/application.ex).

## Project status

**Pre-1.0, active development.** Interfaces may change between 0.x releases.
Chronicle targets a durable BPJS BPMN subset first, not full BPMN 2.0
conformance.

Known limitations:

- No XML BPMN parser (JSON BPJS only).
- Not a complete BPMN 2.0 engine. Unsupported BPMN features are rejected by
  the supported-feature manifest.
- JavaScript sandbox uses raw `node` subprocesses — adequate for trusted
  scripts, not sufficient for executing untrusted tenant code.
- No visual BPMN editor bundled. Use any BPMN 2.0 editor capable of exporting
  the Chronicle JSON schema.

## License

Apache License 2.0. See [`LICENSE`](LICENSE).
