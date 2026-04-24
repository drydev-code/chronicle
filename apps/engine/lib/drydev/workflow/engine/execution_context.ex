defmodule DryDev.Workflow.Engine.ExecutionContext do
  @moduledoc """
  Context passed to node execution functions.
  Replaces NodeExecutionContext from .NET.
  """

  @type t :: %__MODULE__{
    instance_id: String.t(),
    instance_pid: pid(),
    token: DryDev.Workflow.Engine.Token.t(),
    definition: term(),
    node: term(),
    tenant_id: String.t(),
    business_key: String.t(),
    simulation_mode: boolean(),
    simulation_events: [term()],
    simulation_index: non_neg_integer()
  }

  defstruct [
    :instance_id,
    :instance_pid,
    :token,
    :definition,
    :node,
    :tenant_id,
    :business_key,
    simulation_mode: false,
    simulation_events: [],
    simulation_index: 0
  ]

  def new(attrs), do: struct!(__MODULE__, attrs)

  def get_variable(%__MODULE__{token: token}, name) do
    Map.get(token.parameters, name)
  end

  def get_variable(%__MODULE__{token: token}, name, default) do
    Map.get(token.parameters, name, default)
  end

  def next_simulation_event(%__MODULE__{simulation_events: events, simulation_index: idx} = ctx) do
    event = Enum.at(events, idx)
    {event, %{ctx | simulation_index: idx + 1}}
  end
end
