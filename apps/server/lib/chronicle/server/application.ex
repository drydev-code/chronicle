defmodule Chronicle.Server.Application do
  @moduledoc """
  Chronicle.Server OTP Application.
  Transport + host layer: AMQP messaging, external task routing,
  telemetry, and HTTP/Phoenix endpoint.
  """
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Chronicle, []},
      Chronicle.Server.Host.TelemetryService,
      Chronicle.Server.Host.ExternalTaskRouter,
      Chronicle.Server.Messaging.AmqpConnection,
      Chronicle.Server.Messaging.MessageConsumer,
      Chronicle.Server.Web.Endpoint
    ]

    opts = [strategy: :rest_for_one, name: Chronicle.Server.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    Chronicle.Server.Web.Endpoint.config_change(changed, removed)
    :ok
  end
end
