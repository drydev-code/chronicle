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
    lanes: %{term() => map()},
    node_lanes: %{non_neg_integer() => term()},
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
    lanes: %{},
    node_lanes: %{},
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

  def get_conditional_start_events(%__MODULE__{nodes: nodes, start_events: starts}) do
    Enum.filter(starts, fn id ->
      match?(%Chronicle.Engine.Nodes.StartEvents.ConditionalStartEvent{}, Map.get(nodes, id))
    end)
    |> Enum.map(&Map.get(nodes, &1))
  end

  def is_recursive_connection?(%__MODULE__{recursive_connections: rc}, from, to) do
    MapSet.member?(rc, {from, to})
  end

  @doc """
  Static set of catch message-names DECLARED on this definition's own nodes
  (message intermediate-catch events, receive tasks, message boundaries). Only
  statically-resolvable names are returned — dynamic `static_text + variable_content`
  boundary names cannot be known at deploy time and are omitted.
  """
  @spec local_catch_message_names(t()) :: MapSet.t(String.t())
  def local_catch_message_names(%__MODULE__{nodes: nodes}) do
    nodes
    |> Map.values()
    |> Enum.flat_map(&node_catch_message_name/1)
    |> MapSet.new()
  end

  @doc """
  Transitive set of catch message-names reachable from this definition through its
  call/sub-process references — i.e. the message names that THIS instance or any
  child it can statically spawn might catch.

  `lookup_fn` resolves a referenced `process_name` to `{:ok, definition}` (or any
  non-`{:ok, _}` value to skip an unresolvable reference). Recursion is bounded by a
  visited-set over process names (an SCC fixed point over finite definitions), so a
  call cycle terminates.

  Used by the gateway's retention GC: a retained early-arrival message for name N is
  kept while any live instance for the business_key has N in this set (family
  liveness — it covers a not-yet-spawned call-child whose catch is only in its own
  definition).
  """
  @spec reachable_catch_message_names(t(), (String.t() -> {:ok, t()} | term())) ::
          MapSet.t(String.t())
  def reachable_catch_message_names(%__MODULE__{} = definition, lookup_fn)
      when is_function(lookup_fn, 1) do
    {names, _visited} = reachable_catch(definition, lookup_fn, MapSet.new(), MapSet.new())
    names
  end

  defp reachable_catch(%__MODULE__{} = definition, lookup_fn, acc_names, visited) do
    name = definition.name

    if MapSet.member?(visited, name) do
      {acc_names, visited}
    else
      visited = MapSet.put(visited, name)
      acc_names = MapSet.union(acc_names, local_catch_message_names(definition))

      definition.nodes
      |> Map.values()
      |> Enum.flat_map(&called_process_names/1)
      |> Enum.uniq()
      |> Enum.reduce({acc_names, visited}, fn process_name, {names, seen} ->
        case lookup_fn.(process_name) do
          {:ok, %__MODULE__{} = child} -> reachable_catch(child, lookup_fn, names, seen)
          _ -> {names, seen}
        end
      end)
    end
  end

  defp node_catch_message_name(%Chronicle.Engine.Nodes.IntermediateCatch.MessageEvent{message: m}),
    do: static_message_name(m)

  defp node_catch_message_name(%Chronicle.Engine.Nodes.Tasks.ReceiveTask{message: m}),
    do: static_message_name(m)

  defp node_catch_message_name(%Chronicle.Engine.Nodes.BoundaryEvents.MessageBoundary{message: m}),
    do: static_message_name(m)

  defp node_catch_message_name(
         %Chronicle.Engine.Nodes.BoundaryEvents.NonInterruptingMessageBoundary{message: m}
       ),
       do: static_message_name(m)

  defp node_catch_message_name(_node), do: []

  # Only statically-known names. A `static_text + variable_content` message resolves
  # at runtime, so it is intentionally excluded (returns []).
  defp static_message_name(%{static_text: _, variable_content: var}) when not is_nil(var), do: []
  defp static_message_name(%{name: name}) when is_binary(name), do: [name]
  defp static_message_name(name) when is_binary(name), do: [name]
  defp static_message_name(_), do: []

  defp called_process_names(%Chronicle.Engine.Nodes.CallActivity{process_name: name})
       when is_binary(name),
       do: [name]

  defp called_process_names(_node), do: []
end
