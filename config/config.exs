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

config :server, Chronicle.Server.Web.Endpoint,
  url: [host: "localhost"],
  render_errors: [formats: [json: Chronicle.Server.Web.ErrorJSON], layout: false],
  pubsub_server: Chronicle.PubSub,
  live_view: [signing_salt: "chronicle_salt"]

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
