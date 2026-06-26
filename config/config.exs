import Config

config :engine,
  ecto_repos: [Chronicle.Persistence.Repo.MySQL],
  active_repo: Chronicle.Persistence.Repo.MySQL,
  active_databus_repo: Chronicle.Persistence.DataBusRepo.MySQL

config :engine, :eviction,
  enabled: false,
  idle_threshold_ms: 300_000,
  scan_interval_ms: 60_000,
  max_resident: nil

# Ownership-lease layer (feature 3b, phase 2). Disabled by default so the
# single-pod / test path is the EXACT current behaviour: no lease is acquired
# on restore, no renew timers run, and the LeaseManager scan is dormant. A
# production multi-pod deploy sets enabled: true; at N=1 the one pod wins every
# lease, renews forever, never contends, and always fences with its own epoch —
# behaviour identical to disabled.
config :engine, :lease,
  enabled: false,
  ttl_ms: 30_000,
  renew_interval_ms: 10_000,
  scan_interval_ms: 15_000

config :server, Chronicle.Server.Web.Endpoint,
  url: [host: "localhost"],
  render_errors: [formats: [json: Chronicle.Server.Web.ErrorJSON], layout: false],
  pubsub_server: Chronicle.PubSub,
  live_view: [signing_salt: "chronicle_salt"]

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason

config :server, :connector_registry, []
config :server, :amqp_signing, enabled: false, require_signatures: false

import_config "#{config_env()}.exs"
