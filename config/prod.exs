import Config

config :server, Chronicle.Server.Web.Endpoint,
  url: [host: "localhost", port: 443, scheme: "https"]

config :logger, level: :info
