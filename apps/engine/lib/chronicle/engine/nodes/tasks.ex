defmodule Chronicle.Engine.Nodes.Tasks do
  @moduledoc "First-class BPJS task nodes with BPMN-compatible behavior."

  defmodule ManualTask do
    use Chronicle.Engine.Nodes.Node
    defstruct [:id, :key, :inputs, :outputs, :boundary_events, :properties]

    @impl true
    def process(context) do
      first_output = List.first(context.node.outputs || [])
      {:noop_task_completed, :manual_task, first_output}
    end
  end

  defmodule SendTask do
    use Chronicle.Engine.Nodes.Node
    defstruct [:id, :key, :message, :inputs, :outputs, :boundary_events, :properties]

    @impl true
    def process(context) do
      node = context.node
      msg = node.message
      name = resolve_name(msg, context.token.parameters)
      payload = resolve_payload(msg, context.token.parameters, name)
      first_output = List.first(node.outputs || [])
      NodeResult.throw_message(name, payload, first_output)
    end

    defp resolve_name(%{name: name, variable_name: var}, params) when not is_nil(var) do
      Map.get(params, var, name)
    end

    defp resolve_name(%{name: name}, _params), do: name
    defp resolve_name(name, _params) when is_binary(name), do: name
    defp resolve_name(_, _params), do: nil

    defp resolve_payload(msg, params, name) do
      if String.starts_with?(name || "", "__debug") do
        params
      else
        case msg do
          %{payload_variable_name: var} when not is_nil(var) -> Map.get(params, var, %{})
          %{static_text: text} when not is_nil(text) -> text
          _ -> %{}
        end
      end
    end
  end

  defmodule ReceiveTask do
    use Chronicle.Engine.Nodes.Node
    defstruct [:id, :key, :message, :inputs, :outputs, :boundary_events, :properties]

    @impl true
    def simulation_barrier?(), do: true

    @impl true
    def process(context) do
      if context.simulation_mode do
        handle_simulation(context)
      else
        name = resolve_message_name(context.node.message, context.token.parameters)
        NodeResult.wait_for_message(name)
      end
    end

    @impl true
    def continue_after_wait(context) do
      first_output = List.first(context.node.outputs || [])
      NodeResult.next(first_output)
    end

    defp resolve_message_name(%{static_text: text, variable_content: var}, params)
         when not is_nil(var) do
      variable_value = Map.get(params, var, "")
      "#{text}##{variable_value}"
    end

    defp resolve_message_name(%{name: name}, _params), do: name
    defp resolve_message_name(name, _params) when is_binary(name), do: name
    defp resolve_message_name(_, _params), do: nil

    defp handle_simulation(context) do
      {event, _ctx} = ExecutionContext.next_simulation_event(context)

      case event do
        %Chronicle.Engine.PersistentData.MessageHandled{} ->
          first_output = List.first(context.node.outputs || [])
          NodeResult.next(first_output)

        _ ->
          NodeResult.simulation_barrier_then_wait(:waiting_for_message)
      end
    end
  end
end
