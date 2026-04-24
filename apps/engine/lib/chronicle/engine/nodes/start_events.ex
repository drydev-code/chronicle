defmodule Chronicle.Engine.Nodes.StartEvents do
  @moduledoc "All start event types: Blank, Message, Signal, Timer."

  defmodule BlankStartEvent do
    use Chronicle.Engine.Nodes.Node
    defstruct [:id, :key, :kind, :inputs, :outputs, :properties]
    # kind: :unspecified | :ui | :api

    @impl true
    def min_inputs(), do: 0

    @impl true
    def process(context) do
      first_output = List.first(context.node.outputs || [])
      NodeResult.next(first_output)
    end
  end

  defmodule MessageStartEvent do
    use Chronicle.Engine.Nodes.Node
    defstruct [:id, :key, :message, :inputs, :outputs, :properties]

    @impl true
    def min_inputs(), do: 0

    @impl true
    def process(context) do
      first_output = List.first(context.node.outputs || [])
      NodeResult.next(first_output)
    end
  end

  defmodule SignalStartEvent do
    use Chronicle.Engine.Nodes.Node
    defstruct [:id, :key, :signal, :inputs, :outputs, :properties]

    @impl true
    def min_inputs(), do: 0

    @impl true
    def process(context) do
      first_output = List.first(context.node.outputs || [])
      NodeResult.next(first_output)
    end
  end

  defmodule TimerStartEvent do
    use Chronicle.Engine.Nodes.Node
    defstruct [:id, :key, :timer, :inputs, :outputs, :properties]

    @impl true
    def min_inputs(), do: 0

    @impl true
    def process(context) do
      first_output = List.first(context.node.outputs || [])
      NodeResult.next(first_output)
    end
  end
end
