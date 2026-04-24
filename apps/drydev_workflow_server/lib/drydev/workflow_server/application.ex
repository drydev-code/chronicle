defmodule DryDev.WorkflowServer.Application do
  @moduledoc """
  DryDev.WorkflowServer OTP Application.
  Transport + host layer: AMQP messaging, external task routing,
  telemetry, and HTTP/Phoenix endpoint.
  """
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      DryDev.WorkflowServer.Host.TelemetryService,
      DryDev.WorkflowServer.Host.ExternalTaskRouter,
      DryDev.WorkflowServer.Messaging.AmqpConnection,
      DryDev.WorkflowServer.Messaging.MessageConsumer,
      DryDev.WorkflowServer.Web.Endpoint
    ]

    opts = [strategy: :one_for_one, name: DryDev.WorkflowServer.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    DryDev.WorkflowServer.Web.Endpoint.config_change(changed, removed)
    :ok
  end
end
