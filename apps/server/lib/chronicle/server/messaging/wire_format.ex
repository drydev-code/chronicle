defmodule Chronicle.Server.Messaging.WireFormat do
  @moduledoc """
  Util.ServiceBus-compatible serialization.
  Handles envelope format with AMQP type property, headers, and JSON body.

  The Util.ServiceBus library uses:
  - props.Type for message type (format: "AssemblyName+ClassName")
  - Routing key format: "{messageType}.#.{tenantId}" for events
  - Realm headers: "Chronicle.Realm.Any" => "True" for event routing
  """

  @content_type "application/json"

  def encode(message_type, body, opts \\ []) do
    correlation_id = Keyword.get(opts, :correlation_id, UUID.uuid4())
    tenant_id = Keyword.get(opts, :tenant_id)
    realms = Keyword.get(opts, :realms, ["Any"])

    # Realm headers for the Chronicle.Events headers exchange routing
    realm_headers = Map.new(realms, fn realm -> {"Chronicle.Realm.#{realm}", "True"} end)

    headers = Map.merge(realm_headers, %{
      "Chronicle.CorrelationId" => correlation_id
    })

    payload = Jason.encode!(body)

    # Routing key: {messageType}.#.{tenantId}
    tenant_part = if tenant_id && tenant_id != "", do: tenant_id, else: "#"
    routing_key = "#{message_type}.#.#{tenant_part}"

    %{
      message_type: message_type,
      headers: headers,
      payload: payload,
      routing_key: routing_key,
      content_type: @content_type
    }
  end

  @doc """
  Decode an incoming message. Reads message type from metadata.type (AMQP property)
  or falls back to headers for NServiceBus compatibility.
  """
  def decode(metadata, payload) when is_binary(payload) do
    headers = extract_headers(metadata)

    # Util.ServiceBus sets props.Type; NServiceBus uses header
    message_type = get_message_type(metadata, headers)

    body = case Jason.decode(payload) do
      {:ok, decoded} -> normalize_keys(decoded)
      {:error, _} -> %{"raw" => payload}
    end

    %{
      message_type: message_type,
      correlation_id: Map.get(headers, "Chronicle.CorrelationId") || Map.get(headers, "NServiceBus.CorrelationId"),
      body: body
    }
  end

  @doc "Normalize map keys from PascalCase to camelCase for .NET interop."
  def normalize_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_camel(k), normalize_keys(v)} end)
  end
  def normalize_keys(list) when is_list(list), do: Enum.map(list, &normalize_keys/1)
  def normalize_keys(other), do: other

  defp to_camel(key) when is_binary(key) do
    case key do
      <<first::utf8, rest::binary>> when first in ?A..?Z ->
        <<first + 32>> <> rest
      _ -> key
    end
  end
  defp to_camel(key), do: key

  def message_type_match?(decoded, expected) do
    type = decoded.message_type || ""
    String.contains?(type, expected)
  end

  @doc "Build routing key for topic exchange binding."
  def binding_routing_key(message_type) do
    "#{message_type}.#.#"
  end

  # -- Private --

  defp get_message_type(metadata, headers) when is_map(metadata) do
    # Prefer AMQP type property (Util.ServiceBus), fall back to headers (NServiceBus)
    Map.get(metadata, :type) ||
      Map.get(metadata, "type") ||
      Map.get(headers, "NServiceBus.MessageType") ||
      Map.get(headers, "NServiceBus.EnclosedMessageTypes", "")
  end

  defp extract_headers(%{headers: headers}) when is_list(headers) do
    Map.new(headers, fn {key, _type, value} -> {key, value} end)
  end
  defp extract_headers(%{headers: headers}) when is_map(headers), do: headers
  defp extract_headers(_), do: %{}
end
