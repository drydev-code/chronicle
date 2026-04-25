defmodule Chronicle.Server.Host.ExternalTasks.Executors.Helpers do
  @moduledoc "Shared helpers for built-in service task executor plugins."

  alias Chronicle.Server.Host.ExternalTasks.Template
  alias Chronicle.Server.Host.VendorExtensions.ServiceTaskExtension

  def required_binary(value, field) when is_binary(value) do
    if String.trim(value) == "", do: {:error, "#{field} is required"}, else: {:ok, value}
  end

  def required_binary(_value, field), do: {:error, "#{field} is required"}

  def timeout(%ServiceTaskExtension{extensions: extensions}) do
    value = Map.get(extensions || %{}, "timeoutMs", 30_000)

    cond do
      is_integer(value) and value > 0 ->
        {:ok, value}

      is_binary(value) ->
        case Integer.parse(value) do
          {int, ""} when int > 0 -> {:ok, int}
          _ -> {:error, "timeoutMs must be a positive integer"}
        end

      true ->
        {:error, "timeoutMs must be a positive integer"}
    end
  end

  def truthy?(value), do: value in [true, "true", "True", "TRUE", 1, "1"]

  def extension_value(%ServiceTaskExtension{extensions: extensions}, key, default \\ nil) do
    Map.get(extensions || %{}, key, default)
  end

  def result_mode(extension, default) do
    extension
    |> extension_value("resultMode", default)
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  def maybe_extract_result(value, extension) do
    case extension_value(extension, "resultPath") || extension_value(extension, "result") do
      path when is_binary(path) and path != "" -> get_path(value, path)
      _ -> value
    end
  end

  def get_path(value, path) when is_binary(path) do
    path
    |> String.split(".", trim: true)
    |> Enum.reduce(value, fn segment, acc -> get_segment(acc, segment) end)
  end

  def render_to_json_or_string(template, payload) when is_binary(template) do
    with {:ok, rendered} <- Template.render(template, payload || %{}) do
      case Jason.decode(rendered) do
        {:ok, decoded} -> {:ok, decoded}
        {:error, _} -> {:ok, rendered}
      end
    end
  end

  def render_to_json_or_string(value, _payload), do: {:ok, value}

  def render_json_params(template, payload) do
    with {:ok, rendered} <- Template.render(template, payload),
         {:ok, decoded} <- Jason.decode(rendered),
         true <- is_list(decoded) do
      {:ok, decoded}
    else
      false -> {:error, "query params template must render to a JSON array"}
      {:error, reason} -> {:error, "query params template error: #{inspect(reason)}"}
    end
  end

  def normalize_error(%{__struct__: _} = exception) do
    %{
      "error_message" => Exception.message(exception),
      "error_type" => exception.__struct__ |> Module.split() |> List.last()
    }
  end

  def normalize_error(error) when is_map(error), do: error

  def normalize_error(error) do
    %{"error_message" => to_string(error), "error_type" => "BuiltInExecutorError"}
  end

  defp get_segment(nil, _segment), do: nil

  defp get_segment(value, segment) when is_map(value) do
    Map.get(value, segment) || Map.get(value, String.to_existing_atom(segment))
  rescue
    ArgumentError -> Map.get(value, segment)
  end

  defp get_segment(value, segment) when is_list(value) do
    case Integer.parse(segment) do
      {index, ""} -> Enum.at(value, index)
      _ -> nil
    end
  end

  defp get_segment(_value, _segment), do: nil
end
