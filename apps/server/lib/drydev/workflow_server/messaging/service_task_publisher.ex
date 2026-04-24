defmodule DryDev.WorkflowServer.Messaging.ServiceTaskPublisher do
  @moduledoc """
  Publish ServiceTaskExecutionRequestedEvent to message bus.
  Uses Util.ServiceBus topology: events go to DryDev.Events headers exchange
  with routing key "{messageType}.#.{tenantId}" and realm headers.

  Wire format uses PascalCase field names to match .NET Util.ServiceBus serialization.
  """

  alias DryDev.WorkflowServer.Messaging.{WireFormat, AmqpConnection}

  @message_type "DryDev.Messages.Workflow+ServiceTaskExecutionRequestedEvent"
  @default_events_exchange "DryDev.Events"

  def publish(event) do
    body = %{
      "CorrelationId" => event.correlation_id,
      "ProcessId" => event.process_id,
      "ProcessTenantId" => event.tenant_id,
      "ProcessVersion" => 0,
      "ServiceTaskId" => event.service_task_id,
      "ExternalTaskId" => event.external_task_id,
      "Topic" => event.topic,
      "Retry" => 1,
      "Retries" => event.retries,
      "OnException" => event.on_exception,
      "TaskProperties" => encode_task_properties(event.task_properties),
      "Data" => event.data,
      "ActorType" => event.actor_type,
      "TenantId" => event.tenant_id
    }

    envelope = WireFormat.encode(@message_type, body,
      correlation_id: event.correlation_id,
      tenant_id: event.tenant_id
    )

    do_publish(envelope)
  end

  defp encode_task_properties(nil), do: %{}
  defp encode_task_properties(ext) when is_struct(ext) do
    Map.from_struct(ext)
    |> Enum.reject(fn {_k, v} -> is_nil(v) or v == %{} end)
    |> Map.new(fn {k, v} -> {camelize(k), encode_value(k, v)} end)
  end
  defp encode_task_properties(props), do: props

  defp encode_value(:method, atom) when is_atom(atom), do: atom |> Atom.to_string() |> String.upcase()
  defp encode_value(_key, value), do: value

  defp camelize(atom) when is_atom(atom) do
    atom
    |> Atom.to_string()
    |> String.split("_")
    |> case do
      [first | rest] -> first <> Enum.map_join(rest, &String.capitalize/1)
    end
  end

  defp do_publish(envelope) do
    config = Application.get_env(:server, :rabbitmq, [])
    exchange = Keyword.get(config, :events_exchange, @default_events_exchange)
    headers = Map.to_list(envelope.headers)

    case AmqpConnection.publish(exchange, envelope.routing_key, envelope.payload,
      headers: headers,
      type: envelope.message_type
    ) do
      :ok -> :ok
      {:error, :not_connected} ->
        Phoenix.PubSub.broadcast(DryDev.Workflow.PubSub, "messaging:outbound",
          {:service_task_requested, envelope})
        :ok
      error -> error
    end
  end
end
