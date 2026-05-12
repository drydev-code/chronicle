defmodule Chronicle.Engine.MessageCorrelation do
  @moduledoc """
  Boolean correlation checks for message-triggered workflow nodes.
  """

  @correlation_keys ~w(correlation correlationScript correlationExpression)

  def expression(nil), do: nil

  def expression(%{message: message, properties: properties}) do
    expression(message) || expression(properties)
  end

  def expression(%{message: message}) do
    expression(message)
  end

  def expression(%{properties: properties}) do
    expression(properties)
  end

  def expression(message) when is_map(message) do
    @correlation_keys
    |> Enum.find_value(fn key ->
      value = Map.get(message, key) || Map.get(message, String.to_atom(key))
      if value in [nil, ""], do: nil, else: value
    end)
  end

  def expression(_), do: nil

  def message_name(%{name: name}), do: name
  def message_name(name) when is_binary(name), do: name
  def message_name(_), do: nil

  def matches?(node, payload, inputs \\ %{}) do
    case expression(node) do
      script when script in [nil, "", true] ->
        true

      script ->
        node_id = Map.get(node, :id) || "message"

        case Chronicle.Engine.Scripting.ScriptPool.evaluate_expressions(
               [{node_id, script}],
               correlation_inputs(payload, inputs)
             ) do
          {:ok, results} -> truthy_result?(results, node_id)
          _ -> false
        end
    end
  end

  def correlation_inputs(payload, inputs \\ %{}) do
    base =
      %{
        "message" => payload,
        "payload" => payload
      }
      |> put_if_present("messageName", Map.get(inputs || %{}, "messageName"))
      |> put_if_present("messageType", Map.get(inputs || %{}, "messageType"))

    Map.merge(inputs || %{}, base)
  end

  def truthy_result?(results, node_id) when is_list(results) do
    Enum.any?(results, fn
      %{"node_id" => ^node_id, "result" => value} -> truthy?(value)
      %{node_id: ^node_id, result: value} -> truthy?(value)
      {^node_id, value} -> truthy?(value)
      value -> truthy?(value)
    end)
  end

  def truthy_result?(value, _node_id), do: truthy?(value)

  def truthy?(value) when value in [false, nil, 0, "false", "False", "FALSE", ""], do: false
  def truthy?(_), do: true

  defp put_if_present(map, _key, value) when value in [nil, ""], do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)
end
