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
- **External tasks** — service and user task fan-out via AMQP.
- **Process versioning** with `collection@version!tenant/name`.
- **Multi-tenancy** — registry keyed by `{tenant, instance_id}`.
- **Multi-DB** — MySQL, PostgreSQL, MS SQL Server adapters (runtime select).
- **Eviction manager** — idle-process hibernation for high-scale deployments.

## Diagram formats

The engine executes BPJS JSON diagrams and intentionally does not parse native
BPMN XML in this release:

- `.bpjs` — JSON diagram format (accepts PascalCase and camelCase keys).
- `.bpmn`: rejected with an unsupported-format error; XML parsing is out of scope for this release.

Supported BPJS node types are declared in
`Chronicle.Engine.Diagrams.SupportedFeatures`. Lane metadata is supported only
for resolving `actorType` on service/user task publications. Unsupported BPMN
features such as collaborations, pools, participants, message flows,
embedded/event/transaction subprocesses, complex gateways, cancel/multiple
events, and standard multi-instance loop characteristics fail during parsing
instead of silently falling through.

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
