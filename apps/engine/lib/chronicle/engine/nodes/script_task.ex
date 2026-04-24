defmodule Chronicle.Engine.Nodes.ScriptTask do
  @moduledoc "Script Task - executes JavaScript via Node.js port workers."
  use Chronicle.Engine.Nodes.Node

  defstruct [:id, :key, :script, :inputs, :outputs, :boundary_events, :properties]

  @impl true
  def simulation_barrier?(), do: false

  @impl true
  def process(context) do
    node = context.node
    ref = make_ref()

    # Send script to pool worker asynchronously
    Chronicle.Engine.Scripting.ScriptPool.execute_script(
      ref,
      node.script,
      context.token.parameters,
      context.instance_pid
    )

    NodeResult.wait_for_script(ref)
  end

  @impl true
  def continue_after_wait(context) do
    results = context.token.context.continuation_context

    case results do
      {:ok, outputs} when is_map(outputs) ->
        # Merge script outputs into token params
        merged = Map.merge(context.token.parameters, stringify_keys(outputs))
        node = context.node
        first_output = List.first(node.outputs || [])
        if first_output, do: NodeResult.next_with_params(first_output, merged), else: {:complete, %Chronicle.Engine.CompletionData.Blank{}}

      {:ok, _other} ->
        node = context.node
        first_output = List.first(node.outputs || [])
        if first_output, do: NodeResult.next(first_output), else: {:complete, %Chronicle.Engine.CompletionData.Blank{}}

      {:error, error} ->
        boundary = Chronicle.Engine.Nodes.Activity.get_boundary_event_to_exception(
          context.node, %{__struct__: :script_error, message: error}
        )
        if boundary do
          NodeResult.next(boundary.id)
        else
          {:crash, error}
        end
    end
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end
  defp stringify_keys(other), do: other
end
