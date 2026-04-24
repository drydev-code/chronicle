defmodule Chronicle.Engine.Diagrams.Definition do
  @moduledoc """
  ProcessDefinition struct - the parsed representation of a BPMN diagram.
  """

  @type t :: %__MODULE__{
    name: String.t(),
    version: String.t() | nil,
    tenant: String.t() | nil,
    nodes: %{non_neg_integer() => term()},
    connections: %{non_neg_integer() => [non_neg_integer()]},
    reverse_connections: %{non_neg_integer() => [non_neg_integer()]},
    recursive_connections: MapSet.t(),
    start_events: [non_neg_integer()],
    merging_gateways: [non_neg_integer()]
  }

  defstruct [
    :name,
    :version,
    :tenant,
    nodes: %{},
    connections: %{},
    reverse_connections: %{},
    recursive_connections: MapSet.new(),
    start_events: [],
    merging_gateways: []
  ]

  def get_node(%__MODULE__{nodes: nodes}, node_id) do
    Map.get(nodes, node_id)
  end

  def get_outputs(%__MODULE__{connections: conns}, node_id) do
    Map.get(conns, node_id, [])
  end

  def get_inputs(%__MODULE__{reverse_connections: rconns}, node_id) do
    Map.get(rconns, node_id, [])
  end

  def get_blank_start_event(%__MODULE__{nodes: nodes, start_events: starts}) do
    Enum.find_value(starts, fn id ->
      node = Map.get(nodes, id)
      if match?(%Chronicle.Engine.Nodes.StartEvents.BlankStartEvent{}, node), do: node
    end)
  end

  def get_message_start_events(%__MODULE__{nodes: nodes, start_events: starts}) do
    Enum.filter(starts, fn id ->
      match?(%Chronicle.Engine.Nodes.StartEvents.MessageStartEvent{}, Map.get(nodes, id))
    end)
    |> Enum.map(&Map.get(nodes, &1))
  end

  def get_signal_start_events(%__MODULE__{nodes: nodes, start_events: starts}) do
    Enum.filter(starts, fn id ->
      match?(%Chronicle.Engine.Nodes.StartEvents.SignalStartEvent{}, Map.get(nodes, id))
    end)
    |> Enum.map(&Map.get(nodes, &1))
  end

  def get_timer_start_events(%__MODULE__{nodes: nodes, start_events: starts}) do
    Enum.filter(starts, fn id ->
      match?(%Chronicle.Engine.Nodes.StartEvents.TimerStartEvent{}, Map.get(nodes, id))
    end)
    |> Enum.map(&Map.get(nodes, &1))
  end

  def is_recursive_connection?(%__MODULE__{recursive_connections: rc}, from, to) do
    MapSet.member?(rc, {from, to})
  end
end
