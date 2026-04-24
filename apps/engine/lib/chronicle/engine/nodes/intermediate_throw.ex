defmodule Chronicle.Engine.Nodes.IntermediateThrow do
  @moduledoc "Intermediate throwing events: Message, Signal, Error, Escalation."

  defmodule MessageEvent do
    use Chronicle.Engine.Nodes.Node
    defstruct [:id, :key, :message, :inputs, :outputs, :properties]

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
    defp resolve_name(%{name: name}, _), do: name
    defp resolve_name(name, _) when is_binary(name), do: name

    defp resolve_payload(msg, params, name) do
      # Debug messages (__debug*) include all parameters
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

  defmodule SignalEvent do
    use Chronicle.Engine.Nodes.Node
    defstruct [:id, :key, :signal, :inputs, :outputs, :properties]

    @impl true
    def process(context) do
      node = context.node
      first_output = List.first(node.outputs || [])
      NodeResult.throw_signal(node.signal, first_output)
    end
  end

  defmodule ErrorEvent do
    use Chronicle.Engine.Nodes.Node
    defstruct [:id, :key, :error_message, :error_object, :inputs, :outputs, :properties]

    @impl true
    def process(context) do
      node = context.node
      NodeResult.complete(%Chronicle.Engine.CompletionData.Error{
        error_message: node.error_message,
        error_object: node.error_object,
        end_event_key: node.key
      })
    end
  end

  defmodule EscalationEvent do
    use Chronicle.Engine.Nodes.Node
    defstruct [:id, :key, :escalation, :inputs, :outputs, :properties]

    @impl true
    def process(context) do
      node = context.node
      NodeResult.complete(%Chronicle.Engine.CompletionData.Escalation{
        escalation: node.escalation,
        end_event_key: node.key
      })
    end
  end
end
