defmodule DryDev.WorkflowServer.Host.ExternalTasks.UserTask do
  @moduledoc "Form extraction + actor assignment for user tasks."
  alias DryDev.WorkflowServer.Host.ExternalTasks.Template
  alias DryDev.WorkflowServer.Host.VendorExtensions.UserTaskExtension
  alias DryDev.WorkflowServer.Host.LargeVariables

  def handle(event) do
    extension = UserTaskExtension.from_properties(event.properties || %{})

    case render_templates(extension, event.payload) do
      {:ok, rendered_ext} ->
        build_user_task(event, rendered_ext)
      {:error, reason} ->
        send_error_to_instance(event, reason)
    end
  end

  defp render_templates(extension, payload) do
    template_props = UserTaskExtension.template_properties(extension)

    rendered = Enum.reduce_while(template_props, extension, fn {field, value}, acc ->
      case Template.render(value, payload) do
        {:ok, rendered} -> {:cont, Map.put(acc, field, rendered)}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)

    case rendered do
      {:error, _} = err -> err
      ext -> {:ok, ext}
    end
  end

  defp build_user_task(event, extension) do
    assignments = UserTaskExtension.parse_assignments(extension.assignments)

    # Download DataBus references before sending to executor
    payload = if LargeVariables.enabled?() do
      LargeVariables.download(event.payload || %{}, event.tenant_id)
    else
      event.payload
    end

    user_task_command = %{
      task_id: event.task_id,
      instance_id: event.instance_id,
      tenant_id: event.tenant_id,
      business_key: event.business_key,
      view: extension.view,
      assignments: assignments,
      rejectable: extension.rejectable,
      optional: extension.optional,
      subject: extension.subject,
      object: extension.object,
      configuration: extension.configuration,
      data: payload,
      actor_type: extension.actor_type
    }

    DryDev.WorkflowServer.Messaging.UserTaskPublisher.publish(user_task_command)
  end

  defp send_error_to_instance(event, reason) do
    case DryDev.Workflow.Engine.Instance.lookup(event.tenant_id, event.instance_id) do
      {:ok, pid} ->
        error = %{error_message: reason, error_type: "TemplateRenderError"}
        DryDev.Workflow.Engine.Instance.error_external_task(pid, event.task_id, error, false, 0)
      _ -> :ok
    end
  end
end
