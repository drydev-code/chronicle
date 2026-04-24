defmodule DryDev.Workflow.Engine.Nodes.EndEvents do
  @moduledoc "All end event types."
  alias DryDev.Workflow.Engine.CompletionData

  defmodule BlankEndEvent do
    use DryDev.Workflow.Engine.Nodes.Node
    defstruct [:id, :key, :inputs, :outputs, :properties]

    @impl true
    def max_outputs(), do: 0
    @impl true
    def min_outputs(), do: 0

    @impl true
    def process(context) do
      NodeResult.complete(%CompletionData.Blank{end_event_key: context.node.key})
    end
  end

  defmodule ErrorEndEvent do
    use DryDev.Workflow.Engine.Nodes.Node
    defstruct [:id, :key, :error_message, :error_object, :inputs, :outputs, :properties]

    @impl true
    def max_outputs(), do: 0
    @impl true
    def min_outputs(), do: 0

    @impl true
    def process(context) do
      node = context.node
      NodeResult.complete(%CompletionData.Error{
        error_message: node.error_message,
        error_object: node.error_object,
        end_event_key: node.key
      })
    end
  end

  defmodule MessageEndEvent do
    use DryDev.Workflow.Engine.Nodes.Node
    defstruct [:id, :key, :message, :inputs, :outputs, :properties]

    @impl true
    def max_outputs(), do: 0
    @impl true
    def min_outputs(), do: 0

    @impl true
    def process(context) do
      node = context.node
      msg = node.message
      payload = resolve_payload(msg, context.token.parameters)
      name = resolve_message_name(msg, context.token.parameters)

      NodeResult.complete(%CompletionData.Message{
        message_name: name,
        payload: payload,
        end_event_key: node.key
      })
    end

    defp resolve_message_name(%{name: name, variable_name: var_name}, params) when not is_nil(var_name) do
      Map.get(params, var_name, name)
    end
    defp resolve_message_name(%{name: name}, _params), do: name
    defp resolve_message_name(name, _params) when is_binary(name), do: name

    defp resolve_payload(%{payload_variable_name: var}, params) when not is_nil(var) do
      Map.get(params, var, %{})
    end
    defp resolve_payload(_, _), do: %{}
  end

  defmodule SignalEndEvent do
    use DryDev.Workflow.Engine.Nodes.Node
    defstruct [:id, :key, :signal, :inputs, :outputs, :properties]

    @impl true
    def max_outputs(), do: 0
    @impl true
    def min_outputs(), do: 0

    @impl true
    def process(context) do
      NodeResult.complete(%CompletionData.Signal{
        signal: context.node.signal,
        end_event_key: context.node.key
      })
    end
  end

  defmodule EscalationEndEvent do
    use DryDev.Workflow.Engine.Nodes.Node
    defstruct [:id, :key, :escalation, :inputs, :outputs, :properties]

    @impl true
    def max_outputs(), do: 0
    @impl true
    def min_outputs(), do: 0

    @impl true
    def process(context) do
      NodeResult.complete(%CompletionData.Escalation{
        escalation: context.node.escalation,
        end_event_key: context.node.key
      })
    end
  end

  defmodule TerminationEndEvent do
    use DryDev.Workflow.Engine.Nodes.Node
    defstruct [:id, :key, :reason, :inputs, :outputs, :properties]

    @impl true
    def max_outputs(), do: 0
    @impl true
    def min_outputs(), do: 0

    @impl true
    def process(context) do
      NodeResult.complete(%CompletionData.Termination{
        reason: context.node.reason || "Terminated",
        end_event_key: context.node.key
      })
    end
  end
end
