defmodule Chronicle.Server.Host.ExternalTasks.Executors.AI do
  @moduledoc "Built-in AI service task executor plugin backed by REST."

  @behaviour Chronicle.Server.Host.ExternalTasks.Executors.Executor

  alias Chronicle.Server.Host.ExternalTasks.Executors.Rest
  alias Chronicle.Server.Host.ExternalTasks.Executors.Helpers
  alias Chronicle.Server.Host.VendorExtensions.ServiceTaskExtension

  @impl true
  def topics, do: ["ai", "llm"]

  @impl true
  def execute(_event, %ServiceTaskExtension{endpoint: nil}) do
    {:error, "AI tasks require an endpoint and are executed as REST calls"}
  end

  def execute(event, extension) do
    extension =
      if is_nil(extension.body) do
        %{extension | body: ai_body(extension, event.payload)}
      else
        extension
      end

    Rest.execute_request(event, extension, "built_in_ai")
  end

  defp ai_body(%ServiceTaskExtension{extensions: extensions}, payload) do
    extensions = extensions || %{}
    prompt = Map.get(extensions, "prompt")
    messages = Map.get(extensions, "messages")

    base =
      %{}
      |> put_if_present("model", Map.get(extensions, "model"))
      |> put_if_present("temperature", Map.get(extensions, "temperature"))
      |> put_if_present("max_tokens", Map.get(extensions, "maxTokens"))

    cond do
      is_list(messages) ->
        Map.put(base, "messages", render_messages(messages, payload || %{}))

      is_binary(prompt) ->
        {:ok, rendered} = Helpers.render_to_json_or_string(prompt, payload || %{})
        Map.put(base, "prompt", rendered)

      true ->
        Map.put(base, "input", payload || %{})
    end
  end

  defp render_messages(messages, payload) do
    Enum.map(messages, fn
      %{"content" => content} = message when is_binary(content) ->
        {:ok, rendered} = Helpers.render_to_json_or_string(content, payload)
        Map.put(message, "content", rendered)

      message ->
        message
    end)
  end

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, _key, ""), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)
end
