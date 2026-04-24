defmodule DryDev.WorkflowServer.Web.Endpoint do
  use Phoenix.Endpoint, otp_app: :server

  @session_options [
    store: :cookie,
    key: "_drydev_key",
    signing_salt: "drydev_wf",
    same_site: "Lax"
  ]

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library(),
    length: 50_000_000

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug CORSPlug
  plug DryDev.WorkflowServer.Web.Router
end
