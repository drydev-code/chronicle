defmodule Chronicle.Engine.PersistentData do
  @moduledoc """
  All 17 PersistentData types for event sourcing.
  Each struct carries the data needed for restoration/replay.
  """

  defmodule Base do
    @moduledoc "Common fields for persistent data."
    defstruct [:token, :family, :current_node, :timestamp]
  end

  defmodule ProcessInstanceStart do
    defstruct [
      :process_instance_id, :business_key, :tenant, :parent_id,
      :parent_business_key, :root_id, :root_business_key,
      :process_name, :process_version, :start_node_id,
      :started_by_engine, :start_parameters,
      :call_token, :call_family, :call_node,
      token: 0, family: 0, current_node: 0
    ]
  end

  defmodule TokenFamilyCreated do
    defstruct [:token, :family, :current_node, :start_params]
  end

  defmodule TokenFamilyRemoved do
    defstruct [:token, :family, :current_node]
  end

  defmodule ExternalTaskCreation do
    defstruct [:token, :family, :current_node, :external_task, :retry_counter]
  end

  defmodule ExternalTaskCompletion do
    defstruct [
      :token, :family, :current_node, :external_task,
      :successful, :next_node, :payload, :result, :error, :retry_counter
    ]
  end

  defmodule ExternalTaskCancellation do
    defstruct [
      :token, :family, :current_node, :external_task,
      :cancellation_reason, :continuation_node_id, :retry_counter
    ]
  end

  defmodule TimerCreated do
    defstruct [:token, :family, :current_node, :trigger_at, :timer_id, :target_node]
  end

  defmodule TimerElapsed do
    defstruct [:token, :family, :current_node, :target_node, :retry_counter, :timer_id, :triggered_at]
  end

  defmodule TimerCanceled do
    defstruct [:token, :family, :current_node, :target_node, :retry_counter, :timer_id]
  end

  defmodule MessageThrown do
    defstruct [:token, :family, :current_node, :name]
  end

  defmodule MessageHandled do
    defstruct [:token, :family, :current_node, :name, :target_node, :retry_counter, :payload]
  end

  defmodule SignalThrown do
    defstruct [:token, :family, :current_node, :signal_name]
  end

  defmodule SignalHandled do
    defstruct [:token, :family, :current_node, :signal_name, :target_node, :retry_counter]
  end

  defmodule EscalationThrown do
    defstruct [:token, :family, :current_node]
  end

  defmodule CallStarted do
    defstruct [:token, :family, :current_node, :started_process, :loop_index]
  end

  defmodule CallCompleted do
    defstruct [:token, :family, :current_node, :completion_context, :successful, :next_node, :loop_index]
  end

  defmodule CallCanceled do
    defstruct [:token, :family, :current_node, :next_node]
  end

  defmodule ProcessInstanceMigrated do
    defstruct [:from_version, :to_version, :node_mappings, :migrated_tokens]
  end

  @doc "Encode persistent data to a JSON-compatible map."
  def encode(%{__struct__: module} = data) do
    type = module |> Module.split() |> List.last()
    data
    |> Map.from_struct()
    |> Map.put(:type, type)
  end

  @doc "Decode a map back to a persistent data struct."
  def decode(%{"type" => type} = map) do
    module = Module.concat([__MODULE__, type])
    struct(module, atomize_keys(map))
  end

  defp atomize_keys(map) do
    Map.new(map, fn
      {"type", _} -> {:__skip__, nil}
      {k, v} when is_binary(k) -> {String.to_existing_atom(k), v}
      {k, v} -> {k, v}
    end)
    |> Map.delete(:__skip__)
  end
end
