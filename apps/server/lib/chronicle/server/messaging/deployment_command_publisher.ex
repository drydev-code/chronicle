defmodule Chronicle.Server.Messaging.DeploymentCommandPublisher do
  @moduledoc "Send deployment status commands back to Chronicle.Service.Workflow."

  alias Chronicle.Server.Messaging.{WireFormat, AmqpConnection}

  @update_type "Chronicle.Messages.Workflow+UpdateDeploymentCommand"
  @fail_type "Chronicle.Messages.Workflow+FailDeploymentCommand"
  @default_destination "Chronicle.Service.Workflow"

  def send_update(opts) do
    body = %{
      "ExternalId" => opts[:external_id],
      "ExternalProcessDefinitionIds" => opts[:process_ids] || %{}
    }

    send_command(@update_type, body, opts[:tenant_id], opts[:correlation_id])
  end

  def send_failure(opts) do
    body = %{
      "ErrorMessage" => opts[:error_message]
    }

    send_command(@fail_type, body, opts[:tenant_id], opts[:correlation_id])
  end

  defp send_command(message_type, body, tenant_id, correlation_id) do
    envelope = WireFormat.encode(message_type, body,
      correlation_id: correlation_id || UUID.uuid4(),
      tenant_id: tenant_id
    )

    config = Application.get_env(:server, :rabbitmq, [])
    destination = Keyword.get(config, :workflow_service_destination, @default_destination)
    headers = Map.to_list(envelope.headers)

    # Commands go to service fanout exchange
    case AmqpConnection.publish(destination, "", envelope.payload,
      headers: headers,
      type: envelope.message_type
    ) do
      :ok -> :ok
      {:error, :not_connected} ->
        Phoenix.PubSub.broadcast(Chronicle.PubSub, "messaging:outbound",
          {:deployment_command, message_type, body})
        :ok
      error -> error
    end
  end
end
