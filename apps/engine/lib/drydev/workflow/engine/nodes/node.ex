defmodule DryDev.Workflow.Engine.Nodes.Node do
  @moduledoc "Node behaviour definition for all BPMN node types."

  @callback process(context :: DryDev.Workflow.Engine.ExecutionContext.t()) ::
    DryDev.Workflow.Engine.NodeResult.t()

  @callback continue_after_wait(context :: DryDev.Workflow.Engine.ExecutionContext.t()) ::
    DryDev.Workflow.Engine.NodeResult.t()

  @callback simulation_barrier?() :: boolean()
  @callback max_inputs() :: non_neg_integer() | :unlimited
  @callback max_outputs() :: non_neg_integer() | :unlimited
  @callback min_inputs() :: non_neg_integer()
  @callback min_outputs() :: non_neg_integer()

  defmacro __using__(_opts) do
    quote do
      @behaviour DryDev.Workflow.Engine.Nodes.Node
      alias DryDev.Workflow.Engine.{NodeResult, ExecutionContext, Token}

      @impl true
      def continue_after_wait(_context), do: raise "not implemented"

      @impl true
      def simulation_barrier?(), do: false

      @impl true
      def max_inputs(), do: :unlimited

      @impl true
      def max_outputs(), do: :unlimited

      @impl true
      def min_inputs(), do: 1

      @impl true
      def min_outputs(), do: 1

      defoverridable continue_after_wait: 1, simulation_barrier?: 0,
        max_inputs: 0, max_outputs: 0, min_inputs: 0, min_outputs: 0
    end
  end
end
