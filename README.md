# DryDev Workflow

Strict BPMN 2.0 workflow engine for Elixir/OTP. Event-sourced, actor-based,
with DMN decision tables and embedded JavaScript scripting.

## What's in this repo

Umbrella with two apps:

| App                     | Role                                                                 |
| ----------------------- | -------------------------------------------------------------------- |
| `drydev_workflow`       | Engine library — BPMN runtime, DMN evaluator, persistence, scripting |
| `drydev_workflow_server` | Standalone service — Phoenix REST API, AMQP messaging, external task routing |

Use `:drydev_workflow` directly as a hex dependency to embed the engine.
Run `:drydev_workflow_server` when you want a batteries-included HTTP + AMQP
service.

## Features

- **Strict BPMN 2.0 semantics** — start/end events, intermediate catch/throw,
  gateways (exclusive, parallel, inclusive), boundary events, compensation.
- **Token-based execution** on a per-instance `GenServer` with full event
  sourcing (append-only log, replay on restart).
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

The engine parses two BPMN representations:

- `.bpjs` — JSON diagram format (accepts PascalCase and camelCase keys).
- `.bpmn` — recognised by the deployment packager; XML parser is **not** yet
  wired in this OSS release. PRs welcome.

Diagram files are shipped inside ZIP deployment packages alongside
`.dmn` decision tables.

## Quick start (docker)

```bash
git clone <repo> drydev_workflow
cd drydev_workflow
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

```elixir
# mix.exs
def deps do
  [{:drydev_workflow, "~> 0.1"}]
end
```

Then wire your own supervision tree; see
`apps/drydev_workflow/lib/drydev/workflow/application.ex` for the required
children.

## Project status

**Pre-1.0, active development.** Interfaces may change between 0.x releases.
The core execution semantics are a direct port of a production .NET engine
that has been running BPMN workloads since 2022.

Known limitations:

- No XML BPMN parser (JSON bpjs only).
- JavaScript sandbox uses raw `node` subprocesses — adequate for trusted
  scripts, not sufficient for executing untrusted tenant code.
- No visual BPMN editor bundled. Use any BPMN 2.0 editor capable of exporting
  the DryDev JSON schema.

## License

Apache License 2.0. See [`LICENSE`](LICENSE).
