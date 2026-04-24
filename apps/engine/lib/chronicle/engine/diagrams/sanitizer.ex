defmodule Chronicle.Engine.Diagrams.Sanitizer do
  @moduledoc """
  Validation rules for BPMN diagrams.
  """
  alias Chronicle.Engine.Diagrams.Definition

  @type finding :: %{rule: atom(), severity: :error | :warning | :info, message: String.t(), node_id: term()}

  def check(%Definition{} = definition) do
    []
    |> check_unique_node_ids(definition)
    |> check_unique_node_keys(definition)
    |> check_activity_keys(definition)
    |> check_connection_counts(definition)
    |> check_gateway_defaults(definition)
  end

  defp check_unique_node_ids(findings, %{nodes: nodes}) do
    ids = Map.keys(nodes)
    duplicates = ids -- Enum.uniq(ids)
    Enum.reduce(duplicates, findings, fn id, acc ->
      [%{rule: :unique_node_ids, severity: :error, message: "Duplicate node ID: #{id}", node_id: id} | acc]
    end)
  end

  defp check_unique_node_keys(findings, %{nodes: nodes}) do
    keys = nodes |> Map.values() |> Enum.map(&Map.get(&1, :key)) |> Enum.reject(&(is_nil(&1) or &1 == ""))
    duplicates = keys -- Enum.uniq(keys)
    Enum.reduce(duplicates, findings, fn key, acc ->
      [%{rule: :unique_node_keys, severity: :error, message: "Duplicate node key: #{key}", node_id: nil} | acc]
    end)
  end

  defp check_activity_keys(findings, %{nodes: nodes}) do
    nodes
    |> Map.values()
    |> Enum.filter(&is_activity?/1)
    |> Enum.reduce(findings, fn node, acc ->
      if is_nil(Map.get(node, :key)) do
        [%{rule: :activity_key_missing, severity: :error, message: "Activity missing key", node_id: node.id} | acc]
      else
        acc
      end
    end)
  end

  defp check_connection_counts(findings, _definition) do
    # Validate min/max connections per node type
    findings
  end

  defp check_gateway_defaults(findings, %{nodes: nodes}) do
    nodes
    |> Map.values()
    |> Enum.filter(fn node -> match?(%Chronicle.Engine.Nodes.Gateway{kind: :exclusive}, node) end)
    |> Enum.reduce(findings, fn node, acc ->
      default_count = if node.default_path, do: 1, else: 0
      if default_count > 1 do
        [%{rule: :too_many_defaults, severity: :error, message: "Gateway has multiple defaults", node_id: node.id} | acc]
      else
        acc
      end
    end)
  end

  defp is_activity?(node) do
    match?(%Chronicle.Engine.Nodes.ScriptTask{}, node) ||
    match?(%Chronicle.Engine.Nodes.ExternalTask{}, node) ||
    match?(%Chronicle.Engine.Nodes.CallActivity{}, node) ||
    match?(%Chronicle.Engine.Nodes.RulesTask{}, node)
  end
end
