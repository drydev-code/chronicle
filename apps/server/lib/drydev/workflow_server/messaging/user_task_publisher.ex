defmodule DryDev.WorkflowServer.Messaging.UserTaskPublisher do
  @moduledoc """
  Publish CreateUserTaskCommand to domain via AMQP.
  Uses Util.ServiceBus topology: commands go to the destination service's
  fanout exchange (DryDev.{serviceName}).
  """

  alias DryDev.WorkflowServer.Messaging.{WireFormat, AmqpConnection}

  @message_type "DryDev.Messages.Workflow+CreateUserTaskCommand"
  # The .NET service that handles user task commands
  @default_destination "DryDev.Workflow.Service"

  def publish(command) do
    body = %{
      "TaskId" => command.task_id,
      "InstanceId" => command.instance_id,
      "TenantId" => command.tenant_id,
      "BusinessKey" => command.business_key,
      "View" => command[:view],
      "Assignments" => command[:assignments],
      "Rejectable" => command[:rejectable] || false,
      "Optional" => command[:optional] || false,
      "Subject" => command[:subject],
      "Object" => command[:object],
      "Configuration" => command[:configuration],
      "Data" => command[:data] || %{},
      "ActorType" => command[:actor_type]
    }

    envelope = WireFormat.encode(@message_type, body,
      correlation_id: command[:correlation_id],
      tenant_id: command[:tenant_id]
    )

    config = Application.get_env(:server, :rabbitmq, [])
    destination = Keyword.get(config, :user_task_destination, @default_destination)
    headers = Map.to_list(envelope.headers)

    # Commands: publish to destination service's fanout exchange, empty routing key
    case AmqpConnection.publish(destination, "", envelope.payload,
      headers: headers,
      type: envelope.message_type
    ) do
      :ok -> :ok
      {:error, :not_connected} ->
        Phoenix.PubSub.broadcast(DryDev.Workflow.PubSub, "messaging:outbound",
          {:user_task_created, command})
        :ok
      error -> error
    end
  end
end
