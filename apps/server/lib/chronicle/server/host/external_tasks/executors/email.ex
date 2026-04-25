defmodule Chronicle.Server.Host.ExternalTasks.Executors.Email do
  @moduledoc """
  Built-in email service task executor plugin.

  Chronicle does not own SMTP delivery here; this executor validates and
  normalizes the email command so workflows can either inspect the result or
  hand it to an external mail service through another task.
  """

  @behaviour Chronicle.Server.Host.ExternalTasks.Executors.Executor

  alias Chronicle.Server.Host.ExternalTasks.Executors.Helpers

  @impl true
  def topics, do: ["email", "mail"]

  @impl true
  def execute(event, extension) do
    data = Map.merge(extension.extensions || %{}, event.payload || %{})

    with {:ok, to} <- required(data, "to"),
         {:ok, subject} <- required(data, "subject"),
         {:ok, body} <- required(data, "body") do
      email = %{
        "to" => normalize_recipients(to),
        "cc" => normalize_recipients(Map.get(data, "cc")),
        "bcc" => normalize_recipients(Map.get(data, "bcc")),
        "fromEmail" => Map.get(data, "fromEmail"),
        "subject" => subject,
        "body" => body,
        "isHtml" => Helpers.truthy?(Map.get(data, "isHtml")),
        "attachments" => List.wrap(Map.get(data, "attachments", [])),
        "status" => "prepared"
      }

      {:ok, Helpers.maybe_extract_result(email, extension), %{executor: "built_in_email"}}
    end
  end

  defp required(data, key), do: Helpers.required_binary(Map.get(data, key), key)

  defp normalize_recipients(nil), do: []
  defp normalize_recipients(value) when is_list(value), do: value
  defp normalize_recipients(value) when is_binary(value) do
    value
    |> String.split([",", ";"], trim: true)
    |> Enum.map(&String.trim/1)
  end
  defp normalize_recipients(value), do: [to_string(value)]
end
