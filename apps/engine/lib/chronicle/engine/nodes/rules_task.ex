defmodule Chronicle.Engine.Nodes.RulesTask do
  @moduledoc "Business Rule Task - executes DMN decision table."
  use Chronicle.Engine.Nodes.Node

  defstruct [:id, :key, :dmn_name, :return_variable, :inputs, :outputs, :boundary_events, :properties]

  @impl true
  def simulation_barrier?(), do: false

  @impl true
  def process(context) do
    node = context.node
    ref = make_ref()

    Chronicle.Engine.Dmn.DmnStore.evaluate(
      ref,
      node.dmn_name,
      context.token.parameters,
      context.instance_pid,
      context.tenant_id
    )

    NodeResult.wait_for_rules(ref)
  end

  @impl true
  def continue_after_wait(context) do
    results = context.token.context.continuation_context

    case results do
      {:ok, _output} ->
        first_output = List.first(context.node.outputs || [])
        NodeResult.next(first_output)

      {:error, error} ->
        {:crash, error}
    end
  end
end
