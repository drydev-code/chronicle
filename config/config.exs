import Config

config :drydev_workflow,
  ecto_repos: [DryDev.Workflow.Persistence.Repo.MySQL],
  active_repo: DryDev.Workflow.Persistence.Repo.MySQL,
  active_databus_repo: DryDev.Workflow.Persistence.DataBusRepo.MySQL

config :drydev_workflow, :eviction,
  enabled: false,
  idle_threshold_ms: 300_000,
  scan_interval_ms: 60_000,
  max_resident: nil

config :drydev_workflow_server, DryDev.WorkflowServer.Web.Endpoint,
  url: [host: "localhost"],
  render_errors: [formats: [json: DryDev.WorkflowServer.Web.ErrorJSON], layout: false],
  pubsub_server: DryDev.Workflow.PubSub,
  live_view: [signing_salt: "drydev_wf_salt"]

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
