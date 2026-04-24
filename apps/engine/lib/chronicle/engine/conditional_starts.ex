defmodule Chronicle.Engine.ConditionalStarts do
  @moduledoc """
  Evaluates deployed conditional start events against a variable payload.
  """

  alias Chronicle.Engine.Diagrams.{Definition, DiagramStore}
  alias Chronicle.Engine.Instance
  alias Chronicle.Engine.Scripting.ScriptPool

  def evaluate(tenant_id, variables, opts \\ []) when is_map(variables) do
    business_key = Keyword.get(opts, :business_key) || UUID.uuid4()
    process_name = Keyword.get(opts, :process_name)

    tenant_id
    |> DiagramStore.get_definitions_with_conditional_starts()
    |> filter_process_name(process_name)
    |> Enum.flat_map(&matching_starts(&1, variables))
    |> Enum.map(&start_match(&1, tenant_id, business_key, variables, opts))
  end

  defp filter_process_name(definitions, nil), do: definitions
  defp filter_process_name(definitions, name), do: Enum.filter(definitions, &(&1.name == name))

  defp matching_starts(definition, variables) do
    definition
    |> Definition.get_conditional_start_events()
    |> Enum.filter(&condition_matches?(&1, variables))
    |> Enum.map(&{definition, &1})
  end

  defp condition_matches?(%{condition: condition, id: id}, variables) do
    case ScriptPool.evaluate_expressions([{id, condition}], variables) do
      {:ok, results} -> expression_result?(results, id)
      _ -> false
    end
  end

  defp expression_result?(results, node_id) when is_list(results) do
    Enum.any?(results, fn
      %{"node_id" => ^node_id, "result" => true} -> true
      %{node_id: ^node_id, result: true} -> true
      {^node_id, true} -> true
      true -> true
      _ -> false
    end)
  end

  defp expression_result?(true, _node_id), do: true
  defp expression_result?(_, _node_id), do: false

  defp start_match({definition, start_node}, tenant_id, business_key, variables, opts) do
    instance_id = Keyword.get(opts, :id) || UUID.uuid4()

    params = %{
      id: instance_id,
      business_key: business_key,
      tenant_id: tenant_id,
      start_parameters: variables,
      start_node_id: start_node.id,
      started_by_engine: true
    }

    case DynamicSupervisor.start_child(
           Chronicle.Engine.InstanceSupervisor,
           {Instance, {definition, params}}
         ) do
      {:ok, _pid} ->
        {:ok, %{process_instance_id: instance_id, process_name: definition.name, start_node_id: start_node.id}}

      {:error, reason} ->
        {:error, %{process_name: definition.name, start_node_id: start_node.id, reason: reason}}
    end
  end
end
