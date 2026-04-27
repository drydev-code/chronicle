defmodule Chronicle.Server.Host.ExternalTasks.ServiceTask do
  @moduledoc "Template render + publish to bus for service tasks."
  alias Chronicle.Server.Host.ExternalTasks.Template
  alias Chronicle.Server.Host.ExternalTasks.BuiltInExecutor
  alias Chronicle.Server.Host.ExternalTasks.ConnectorRegistry
  alias Chronicle.Server.Host.VendorExtensions.ServiceTaskExtension
  alias Chronicle.Server.Host.LargeVariables

  def handle(event) do
    extension = ServiceTaskExtension.from_properties(event.properties || %{})

    # Render all template properties
    case render_templates(extension, event.payload) do
      {:ok, rendered_ext} ->
        build_and_publish(event, rendered_ext)

      {:error, reason} ->
        # Template error -> error command back to instance
        send_error_to_instance(event, reason)
    end
  end

  defp render_templates(extension, payload) do
    template_props = ServiceTaskExtension.template_properties(extension)

    rendered =
      Enum.reduce_while(template_props, extension, fn {field, value}, acc ->
        case Template.render(value, payload) do
          {:ok, rendered} -> {:cont, Map.put(acc, field, rendered)}
          {:error, reason} -> {:halt, {:error, "Template error in #{field}: #{reason}"}}
        end
      end)

    case rendered do
      {:error, _} = err -> err
      ext -> {:ok, ext}
    end
  end

  defp build_and_publish(event, extension) do
    actor_type = extension.actor_type || "Actor"
    _user_id = Map.get(event.payload || %{}, "userId")

    # Download DataBus references before sending to executor
    payload =
      if LargeVariables.enabled?() do
        LargeVariables.download(event.payload || %{}, event.tenant_id)
      else
        event.payload
      end

    placement = ConnectorRegistry.resolve(extension)
    extension = apply_placement_metadata(extension, placement)

    service_task_event = %{
      correlation_id: event.instance_id,
      process_id: event.instance_id,
      service_task_id: event.node_key,
      external_task_id: event.task_id,
      topic: extension.topic,
      retries: extension.retries,
      on_exception: extension.on_exception,
      task_properties: extension,
      execution: extension.execution,
      data: payload,
      actor_type: actor_type,
      tenant_id: event.tenant_id
    }

    dispatch(service_task_event, event, extension, placement.placement)
  end

  defp dispatch(service_task_event, _event, _extension, placement)
       when placement in [:satellite, :amqp],
       do: Chronicle.Server.Messaging.ServiceTaskPublisher.publish(service_task_event)

  defp dispatch(service_task_event, event, extension, :local) do
    event
    |> Map.put(:payload, service_task_event.data)
    |> BuiltInExecutor.execute_async(extension)
  end

  defp dispatch(service_task_event, event, extension, _placement) do
    if BuiltInExecutor.supported?(extension) do
      event
      |> Map.put(:payload, service_task_event.data)
      |> BuiltInExecutor.execute_async(extension)
    else
      Chronicle.Server.Messaging.ServiceTaskPublisher.publish(service_task_event)
    end
  end

  defp apply_placement_metadata(extension, %{connector: connector, execution: execution}) do
    %{extension | connector: empty_to_nil(connector), execution: empty_to_nil(execution)}
  end

  defp empty_to_nil(map) when map == %{}, do: nil
  defp empty_to_nil(value), do: value

  defp send_error_to_instance(event, reason) do
    case Chronicle.Engine.Instance.lookup(event.tenant_id, event.instance_id) do
      {:ok, pid} ->
        error = %{error_message: reason, error_type: "TemplateRenderError"}
        Chronicle.Engine.Instance.error_external_task(pid, event.task_id, error, false, 0)

      _ ->
        :ok
    end
  end
end
