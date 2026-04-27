# Next Phase Handoff Prompt

You are working in `D:\Drydev\chronicle`.

Goal: implement the next Chronicle BPJS BPMN subset phase or production
hardening batch without regressing the current event-sourced runtime,
connector registry, or satellite architecture.

Start by reading:

- `README.md`
- `review/bpmn-feature-matrix.md`
- `review/remaining-engine-work.md`
- `review/integration-feature-gap-todos.md`
- `review/satellite-architecture-todos.md`
- `review/satellite-observability.md`
- `apps/engine/lib/chronicle/engine/diagrams/parser.ex`
- `apps/engine/lib/chronicle/engine/diagrams/supported_features.ex`
- `apps/engine/lib/chronicle/engine/diagrams/definition.ex`
- `apps/engine/lib/chronicle/engine/instance.ex`
- `apps/engine/lib/chronicle/engine/token_processor.ex`
- `apps/engine/lib/chronicle/engine/instance/boundary_lifecycle.ex`
- `apps/engine/lib/chronicle/engine/instance/wait_registry.ex`
- `apps/engine/lib/chronicle/engine/instance/event_replayer.ex`
- `apps/server/lib/chronicle/server/host/external_task_router.ex`
- `apps/server/lib/chronicle/server/host/external_tasks/connector_registry.ex`
- `apps/server/lib/chronicle/server/messaging/message_signature.ex`
- `satellites/README.md`
- `satellites/rest-ai/main.py`
- `satellites/database/main.py`
- `satellites/email-transform/main.py`
- `satellites/shared/python/chronicle_satellite/app.py`
- `satellites/shared/python/chronicle_satellite/executors/rest_ai.py`
- `satellites/shared/python/chronicle_satellite/executors/database.py`

Current baseline:

- Branch pushed: `main`.
- Latest merged commit: `ea14208 Implement Chronicle satellite connectors`.
- Last full verification before push:
  - Docker engine suite: 102 tests, 0 failures.
  - Docker server suite: 40 tests, 0 failures.
  - Python satellite tests: 44 tests, 0 failures.
  - Python signing tests: 6 tests, 0 failures.
  - `python scripts/smoke_satellite_examples.py`.
  - Docker Compose satellite smoke: deployed and started all satellite example
    diagrams; happy paths completed; intentional REST auth failure became a
    Chronicle `ServiceTaskFailedEvent`.

Hard constraints:

- Do not implement native BPMN XML import unless explicitly scoped.
- Event log is source of truth. Commands must append durable events before
  mutating projections, continuing tokens, publishing PubSub/AMQP effects, or
  acknowledging work.
- Query/read paths must not mutate workflow state.
- Unsupported BPMN features must fail during parsing/runtime validation.
- Update `SupportedFeatures` only when parseable, executable, replayable, and
  tested.
- Keep service-task placement based on BPJS task properties and the connector
  registry. Do not reintroduce `SATELLITE_TOPICS` as a Chronicle routing
  contract.
- Keep BPMN business failures in Chronicle state. RabbitMQ retry/DLQ handling
  is for transport failures before Chronicle receives a connector response.
- Keep AMQP signing/verification and certificate pinning behavior covered by
  tests when changing message envelopes.

Current open production hardening candidates:

1. Replace development `x-user-id` auth with production authentication:
   API keys, JWT/JWKS, OIDC, route scopes, tenant authorization, and audit
   logging.
2. Add tenant-scoped connector authorization before dispatch.
3. Add secret-provider references for REST, AI, database, email, and future
   connectors, starting with environment references and leaving room for
   Vault, Kubernetes, and cloud secret managers.
4. Add per-connector health/status, concurrency limits, circuit breakers,
   rate-limit metrics, and outbound host allowlists.
5. Add provider certification tests using real deployment credentials and
   network/TLS policy for the concrete REST providers, AI gateways, and
   databases a deployment uses.

Current open BPMN candidates:

1. Embedded subprocesses with scoped variables and scoped boundary events.
2. Event subprocesses, including interrupting/non-interrupting starts.
3. Transaction subprocesses with cancel semantics.
4. Multiple and parallel-multiple events.
5. Standard sequential/parallel multi-instance activity characteristics.

Before final response on the next implementation batch:

- Run the relevant focused tests.
- For cross-cutting runtime changes, also run:
  - `docker compose --profile test build test`
  - `docker compose --profile test run --rm test`
- For satellite changes, also run:
  - `$env:PYTHONPATH='satellites/shared/python'; python -m unittest discover -s satellites\shared\python\tests -v`
  - `$env:PYTHONPATH='satellites/shared/python'; python -m unittest discover -s satellites\shared\python -p '*test*.py' -v`
  - `python scripts\smoke_satellite_examples.py`
- Update README and review docs in the same change.
