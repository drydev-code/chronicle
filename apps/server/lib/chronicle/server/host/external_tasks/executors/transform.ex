defmodule Chronicle.Server.Host.ExternalTasks.Executors.Transform do
  @moduledoc """
  Built-in transform/echo executor.

  Useful for glue workflows and tests where a service task should derive a
  payload from current variables without leaving Chronicle.
  """

  @behaviour Chronicle.Server.Host.ExternalTasks.Executors.Executor

  alias Chronicle.Server.Host.ExternalTasks.Executors.Helpers

  @impl true
  def topics, do: ["transform", "echo", "map"]

  @impl true
  def execute(event, extension) do
    template =
      extension.body ||
        Helpers.extension_value(extension, "template") ||
        Helpers.extension_value(extension, "value")

    result =
      case template do
        nil -> {:ok, event.payload || %{}}
        value -> Helpers.render_to_json_or_string(value, event.payload || %{})
      end

    with {:ok, payload} <- result do
      {:ok, Helpers.maybe_extract_result(payload, extension), %{executor: "built_in_transform"}}
    end
  end
end
