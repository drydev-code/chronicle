defmodule Chronicle.Server.Host.ExternalTasks.Executors.Registry do
  @moduledoc """
  Registry for built-in service task executor plugins.

  The default plugin list can be extended or replaced via:

      config :server, :service_task_executors, [MyExecutor]
  """

  alias Chronicle.Server.Host.VendorExtensions.ServiceTaskExtension

  @default_executors [
    Chronicle.Server.Host.ExternalTasks.Executors.Rest,
    Chronicle.Server.Host.ExternalTasks.Executors.Database,
    Chronicle.Server.Host.ExternalTasks.Executors.AI,
    Chronicle.Server.Host.ExternalTasks.Executors.Email,
    Chronicle.Server.Host.ExternalTasks.Executors.Transform
  ]

  def executors do
    Application.get_env(:server, :service_task_executors, @default_executors)
  end

  def executor_for(%ServiceTaskExtension{topic: topic}) when is_binary(topic) do
    normalized = normalize_topic(topic)

    Enum.find(executors(), fn executor ->
      normalized in Enum.map(executor.topics(), &normalize_topic/1)
    end)
  end

  def executor_for(_extension), do: nil

  defp normalize_topic(topic), do: topic |> String.trim() |> String.downcase()
end
