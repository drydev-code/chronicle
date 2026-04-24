defmodule DryDev.WorkflowServer.Host.VendorExtensions do
  @moduledoc "ServiceTaskExtension + UserTaskExtension parsing."

  defmodule ServiceTaskExtension do
    defstruct [
      :topic, :service, :endpoint, :result_variable, :on_exception,
      :retries, :method, :body, :actor_type, :extensions
    ]

    def from_properties(props) when is_map(props) do
      %__MODULE__{
        topic: Map.get(props, "topic"),
        service: Map.get(props, "service"),
        endpoint: Map.get(props, "endPoint") || Map.get(props, "endpoint"),
        result_variable: Map.get(props, "resultVariable"),
        on_exception: Map.get(props, "onException"),
        retries: Map.get(props, "retries", 0),
        method: parse_method(Map.get(props, "method", "Post")),
        body: Map.get(props, "body"),
        actor_type: Map.get(props, "actorType", "Actor"),
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
        _ -> :post
      end
    end
    defp parse_method(_), do: :post
  end

  defmodule UserTaskExtension do
    defstruct [
      :view, :assignments, :mode, :step, :rejectable, :optional,
      :subject, :object, :configuration, :relations, :actor_type, :extensions
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
end
