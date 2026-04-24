import Config

config :server, DryDev.WorkflowServer.Web.Endpoint,
  url: [host: "localhost", port: 443, scheme: "https"]

config :logger, level: :info
