defmodule DryDev.WorkflowServer.Host.ExternalTasks.Handler do
  @moduledoc "Route external task events to service/user task logic."

  alias DryDev.WorkflowServer.Host.ExternalTasks.{ServiceTask, UserTask}

  def handle_external_task(event) do
    %{task_id: _task_id, kind: kind, business_key: _bk, tenant_id: _tenant,
      payload: _payload, node_key: _node_key, instance_id: _instance_id} = event

    case kind do
      :service -> ServiceTask.handle(event)
      :user -> UserTask.handle(event)
    end
  end

  def handle_cancellation(task_id, kind, reason) do
    case kind do
      :service ->
        # Create FailServiceTaskCommand with IsDeletedTask flag
        %{task_id: task_id, command: :fail_service_task, is_deleted: true, reason: reason}
      :user ->
        # Create RejectUserTaskCommand with IsDeletedTask flag
        %{task_id: task_id, command: :reject_user_task, is_deleted: true, reason: reason}
    end
  end
end
