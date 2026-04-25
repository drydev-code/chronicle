defmodule Chronicle.Server.Host.ExternalTasks.BuiltInExecutor do
  @moduledoc """
  Built-in service task executor facade.

  Execution is provided by executor plugins under
  `Chronicle.Server.Host.ExternalTasks.Executors`. This module keeps the
  service-task integration small and routes completion/failure through the
  normal durable external-task command path.
  """

  require Logger

  alias Chronicle.Server.Host.ExternalTaskRouter
  alias Chronicle.Server.Host.ExternalTasks.Executors.Registry
  alias Chronicle.Server.Host.ExternalTasks.Executors.Helpers
  alias Chronicle.Server.Host.VendorExtensions.ServiceTaskExtension

  def supported?(%ServiceTaskExtension{} = extension), do: not is_nil(Registry.executor_for(extension))
  def supported?(_), do: false

  def execute_async(event, %ServiceTaskExtension{} = extension) do
    Task.start(fn -> execute(event, extension) end)
    :ok
  end

  def execute(event, %ServiceTaskExtension{} = extension) do
    result =
      case Registry.executor_for(extension) do
        nil -> {:error, "No built-in executor registered for topic #{inspect(extension.topic)}"}
        executor -> executor.execute(event, extension)
      end

    case result do
      {:ok, payload, task_result} ->
        ExternalTaskRouter.complete_task(event.task_id, payload, task_result)

      {:error, error} ->
        ExternalTaskRouter.fail_task(event.task_id, Helpers.normalize_error(error), false, 0)
    end
  rescue
    exception ->
      Logger.error("BuiltInExecutor: task #{inspect(event.task_id)} crashed: #{Exception.message(exception)}")
      ExternalTaskRouter.fail_task(event.task_id, Helpers.normalize_error(exception), false, 0)
  end
end
