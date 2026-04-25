defmodule Chronicle.Server.Host.ExternalTasks.Executors.Rest do
  @moduledoc "Built-in REST/HTTP service task executor plugin."

  @behaviour Chronicle.Server.Host.ExternalTasks.Executors.Executor

  alias Chronicle.Server.Host.ExternalTasks.Executors.Helpers
  alias Chronicle.Server.Host.ExternalTasks.Template
  alias Chronicle.Server.Host.VendorExtensions.ServiceTaskExtension

  @impl true
  def topics, do: ["rest", "http", "https"]

  @impl true
  def execute(event, extension) do
    execute_request(event, extension, "built_in_rest")
  end

  def execute_request(event, extension, executor_name) do
    with {:ok, endpoint} <- Helpers.required_binary(extension.endpoint, "endpoint"),
         {:ok, body} <- request_body(extension, event.payload),
         {:ok, headers} <- request_headers(extension),
         {:ok, timeout} <- Helpers.timeout(extension),
         {:ok, response} <- do_http_request(extension.method, endpoint, headers, body, timeout) do
      handle_response(response, extension, executor_name)
    end
  end

  defp do_http_request(method, endpoint, headers, nil, timeout)
       when method in [:get, :delete] do
    request = {String.to_charlist(endpoint), headers}
    http_opts = [timeout: timeout, connect_timeout: timeout]
    opts = [body_format: :binary]

    case :httpc.request(method, request, http_opts, opts) do
      {:ok, response} -> {:ok, normalize_http_response(response)}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp do_http_request(method, endpoint, headers, body, timeout) do
    content_type = content_type(headers)
    request = {String.to_charlist(endpoint), headers, content_type, body || ""}
    http_opts = [timeout: timeout, connect_timeout: timeout]
    opts = [body_format: :binary]

    case :httpc.request(method || :post, request, http_opts, opts) do
      {:ok, response} -> {:ok, normalize_http_response(response)}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp normalize_http_response({{_version, status, reason}, headers, body}) do
    %{
      "status" => status,
      "reason" => to_string(reason),
      "headers" => normalize_headers(headers),
      "body" => decode_body(body)
    }
  end

  defp handle_response(response, extension, executor_name) do
    fail_on_status? = Helpers.extension_value(extension, "failOnStatus", true) != false
    status = Map.get(response, "status", 0)

    cond do
      fail_on_status? and status >= 400 ->
        {:error,
         %{
           "error_message" => "HTTP request failed with status #{status}",
           "error_type" => "HttpStatusError",
           "status" => status,
           "response" => response
         }}

      true ->
        {:ok, shape_result(response, extension), %{executor: executor_name, status: status}}
    end
  end

  defp shape_result(response, extension) do
    result =
      case Helpers.result_mode(extension, "response") do
        "body" -> Map.get(response, "body")
        "status" -> Map.take(response, ["status", "reason"])
        "headers" -> Map.get(response, "headers", %{})
        _ -> response
      end

    Helpers.maybe_extract_result(result, extension)
  end

  defp request_body(%ServiceTaskExtension{body: nil}, _payload), do: {:ok, nil}

  defp request_body(%ServiceTaskExtension{body: body}, payload) when is_binary(body) do
    case Template.render(body, payload || %{}) do
      {:ok, rendered} -> {:ok, rendered}
      {:error, reason} -> {:error, "Template error in body: #{reason}"}
    end
  end

  defp request_body(%ServiceTaskExtension{body: body}, _payload) when is_map(body) or is_list(body) do
    Jason.encode(body)
  end

  defp request_body(%ServiceTaskExtension{body: body}, _payload), do: {:ok, to_string(body)}

  defp request_headers(%ServiceTaskExtension{extensions: extensions}) do
    raw_headers = Map.get(extensions || %{}, "headers", %{})

    headers =
      cond do
        is_map(raw_headers) ->
          Enum.map(raw_headers, fn {key, value} -> {header_chars(key), header_chars(value)} end)

        is_list(raw_headers) ->
          Enum.map(raw_headers, fn
            {key, value} -> {header_chars(key), header_chars(value)}
            [key, value] -> {header_chars(key), header_chars(value)}
          end)

        true ->
          []
      end

    headers =
      headers
      |> maybe_put_bearer(Map.get(extensions || %{}, "bearerToken"))
      |> maybe_put_bearer_env(Map.get(extensions || %{}, "bearerTokenEnv") || Map.get(extensions || %{}, "apiKeyEnv"))

    {:ok, ensure_content_type(headers)}
  end

  defp ensure_content_type(headers) do
    if Enum.any?(headers, fn {key, _} -> String.downcase(to_string(key)) == "content-type" end) do
      headers
    else
      [{~c"content-type", ~c"application/json"} | headers]
    end
  end

  defp content_type(headers) do
    headers
    |> Enum.find_value(~c"application/json", fn {key, value} ->
      if String.downcase(to_string(key)) == "content-type", do: value
    end)
    |> to_charlist()
  end

  defp normalize_headers(headers) do
    Map.new(headers, fn {key, value} -> {to_string(key), to_string(value)} end)
  end

  defp decode_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _} -> body
    end
  end

  defp header_chars(value), do: value |> to_string() |> String.to_charlist()

  defp maybe_put_bearer(headers, token) when is_binary(token) and token != "" do
    [{~c"authorization", header_chars("Bearer #{token}")} | headers]
  end

  defp maybe_put_bearer(headers, _token), do: headers

  defp maybe_put_bearer_env(headers, env_name) when is_binary(env_name) and env_name != "" do
    maybe_put_bearer(headers, System.get_env(env_name))
  end

  defp maybe_put_bearer_env(headers, _env_name), do: headers
end
