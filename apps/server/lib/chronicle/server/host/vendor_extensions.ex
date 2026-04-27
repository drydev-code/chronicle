defmodule Chronicle.Server.Host.VendorExtensions do
  @moduledoc "ServiceTaskExtension + UserTaskExtension parsing."

  @execution_metadata_keys ~w(
    retries maxRetries retry retryPolicy retryDelay retryDelayMs retryDelays
    retryOn retryOnStatus statusCodes backoff backoffMs initialBackoffMs
    maxBackoffMs jitter retryJitter retryUnsafe retryExceptions
    respectRetryAfter maxRuntime maxRuntimeMs runtimeTimeout
    runtimeTimeoutMs leaseTimeout leaseTimeoutMs timeout timeoutMs deadline
    priority queue placement
  )

  defmodule ServiceTaskExtension do
    defstruct [
      :topic,
      :service,
      :endpoint,
      :result_variable,
      :on_exception,
      :retries,
      :method,
      :body,
      :actor_type,
      :connector,
      :execution,
      :extensions
    ]

    def from_properties(props) when is_map(props) do
      execution = Chronicle.Server.Host.VendorExtensions.execution_metadata(props)

      %__MODULE__{
        topic: Map.get(props, "topic"),
        service: Map.get(props, "service"),
        endpoint: Map.get(props, "endPoint") || Map.get(props, "endpoint"),
        result_variable: Map.get(props, "resultVariable"),
        on_exception: Map.get(props, "onException"),
        retries: retry_count(props, execution),
        method: parse_method(Map.get(props, "method", "Post")),
        body: Map.get(props, "body") || Map.get(props, "requestBody"),
        actor_type: Map.get(props, "actorType", "Actor"),
        connector: connector_properties(props),
        execution: empty_to_nil(execution),
        extensions: Map.get(props, "extensions", %{})
      }
    end

    def template_properties(%__MODULE__{} = ext) do
      [:topic, :service, :endpoint, :result_variable, :body, :actor_type]
      |> Enum.map(fn field -> {field, Map.get(ext, field)} end)
      |> Enum.reject(fn {_, v} -> is_nil(v) end)
    end

    defp parse_method(method) when is_binary(method) do
      case String.upcase(method) do
        "GET" -> :get
        "POST" -> :post
        "PUT" -> :put
        "DELETE" -> :delete
        "PATCH" -> :patch
        _ -> :post
      end
    end

    defp parse_method(_), do: :post

    defp retry_count(props, execution) do
      Map.get(props, "retries") ||
        Map.get(execution || %{}, "retries") ||
        Map.get(execution || %{}, "maxRetries") ||
        0
    end

    defp connector_properties(props) do
      cond do
        is_map(Map.get(props, "connector")) ->
          Map.get(props, "connector")

        is_binary(Map.get(props, "connectorId")) ->
          %{"id" => Map.get(props, "connectorId")}

        is_binary(get_in(props, ["extensions", "connectorId"])) ->
          %{"id" => get_in(props, ["extensions", "connectorId"])}

        is_binary(get_in(props, ["extensions", "connectionId"])) ->
          %{"id" => get_in(props, ["extensions", "connectionId"])}

        true ->
          nil
      end
    end

    defp empty_to_nil(map) when map == %{}, do: nil
    defp empty_to_nil(value), do: value
  end

  defmodule UserTaskExtension do
    defstruct [
      :view,
      :assignments,
      :mode,
      :step,
      :rejectable,
      :optional,
      :subject,
      :object,
      :configuration,
      :relations,
      :actor_type,
      :extensions
    ]

    def from_properties(props) when is_map(props) do
      %__MODULE__{
        view: Map.get(props, "view"),
        assignments: Map.get(props, "assignments"),
        mode: Map.get(props, "mode", "continue"),
        step: Map.get(props, "step"),
        rejectable: Map.get(props, "rejectable", false),
        optional: Map.get(props, "optional", false),
        subject: Map.get(props, "subject"),
        object: Map.get(props, "object"),
        configuration: Map.get(props, "configuration"),
        relations: Map.get(props, "relations"),
        actor_type: Map.get(props, "actorType", "Actor"),
        extensions: Map.get(props, "extensions", %{})
      }
    end

    def template_properties(%__MODULE__{} = ext) do
      [:view, :subject, :object, :configuration, :relations, :actor_type]
      |> Enum.map(fn field -> {field, Map.get(ext, field)} end)
      |> Enum.reject(fn {_, v} -> is_nil(v) end)
    end

    def parse_assignments(nil), do: []

    def parse_assignments(str) when is_binary(str) do
      str
      |> String.split("\n", trim: true)
      |> Enum.map(fn line ->
        case String.split(line, ":", parts: 2) do
          [type, value] -> %{type: String.trim(type), value: String.trim(value)}
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)
    end
  end

  def execution_metadata(props) when is_map(props) do
    extensions = Map.get(props, "extensions", %{})

    %{}
    |> Map.merge(normalize_metadata_map(Map.get(extensions, "execution")))
    |> Map.merge(normalize_metadata_map(Map.get(props, "execution")))
    |> Map.merge(runtime_metadata(extensions))
    |> Map.merge(runtime_metadata(props))
    |> compact_map()
  end

  def execution_metadata(_props), do: %{}

  defp runtime_metadata(value) when is_map(value) do
    value
    |> Map.take(@execution_metadata_keys)
    |> compact_map()
  end

  defp runtime_metadata(_value), do: %{}

  defp normalize_metadata_map(value) when is_map(value), do: value
  defp normalize_metadata_map(_value), do: %{}

  defp compact_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, "", %{}, []] end)
    |> Map.new()
  end
end
