defmodule Chronicle.Server.Host.TelemetryService do
  @moduledoc """
  In-memory telemetry service tracking process instances and token movements.
  Subscribes to engine PubSub events and stores data in ETS.
  """
  use GenServer
  require Logger

  @table :telemetry_instances
  @definitions_table :telemetry_definitions
  @errors_table :telemetry_errors

  # -- Public API --

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def enabled? do
    GenServer.call(__MODULE__, :enabled?)
  end

  def start_collection do
    GenServer.call(__MODULE__, :start)
  end

  def stop_collection do
    GenServer.call(__MODULE__, :stop)
  end

  def get_all_instances do
    :ets.tab2list(@table)
    |> Enum.map(fn {_key, data} -> data end)
  end

  def get_instance(instance_id) do
    case :ets.lookup(@table, instance_id) do
      [{_key, data}] -> {:ok, data}
      [] -> {:error, :not_found}
    end
  end

  def get_terminated_instances do
    :ets.tab2list(@table)
    |> Enum.filter(fn {_key, data} -> data.state == :terminated end)
    |> Enum.map(fn {_key, data} -> data.id end)
  end

  def get_process_definitions do
    :ets.tab2list(@definitions_table)
    |> Map.new(fn {name, def_data} -> {name, def_data} end)
  end

  def get_process_definition(name) do
    case :ets.lookup(@definitions_table, name) do
      [{_name, definition}] -> {:ok, definition}
      [] -> {:error, :not_found}
    end
  end

  def add_process_definition(name, definition) do
    :ets.insert(@definitions_table, {name, definition})
  end

  def get_errors(type) do
    :ets.match_object(@errors_table, {type, :_})
    |> Enum.map(fn {_type, data} -> data end)
  end

  def get_start_not_found_errors do
    get_errors(:start_not_found)
  end

  def get_already_running_errors do
    get_errors(:already_running)
  end

  @doc "Remove completed instances from telemetry."
  def remove_completed(remove_successful \\ true, remove_failed \\ false) do
    :ets.tab2list(@table)
    |> Enum.each(fn {key, data} ->
      cond do
        data.state == :completed and data.successful and remove_successful ->
          :ets.delete(@table, key)

        data.state == :completed and not data.successful and remove_failed ->
          :ets.delete(@table, key)

        data.state == :terminated and remove_failed ->
          :ets.delete(@table, key)

        true ->
          :ok
      end
    end)
  end

  def set_drop_successful(value) when is_boolean(value) do
    GenServer.call(__MODULE__, {:set_drop_successful, value})
  end

  def drop_successful? do
    GenServer.call(__MODULE__, :drop_successful?)
  end

  # -- Server callbacks --

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    :ets.new(@definitions_table, [:named_table, :set, :public, read_concurrency: true])
    :ets.new(@errors_table, [:named_table, :bag, :public, read_concurrency: true])

    state = %{
      enabled: false,
      drop_successful: false
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:enabled?, _from, state), do: {:reply, state.enabled, state}

  def handle_call(:start, _from, state) do
    unless state.enabled do
      Phoenix.PubSub.subscribe(Chronicle.PubSub, "engine:events")
    end

    {:reply, :ok, %{state | enabled: true}}
  end

  def handle_call(:stop, _from, state) do
    if state.enabled do
      Phoenix.PubSub.unsubscribe(Chronicle.PubSub, "engine:events")
    end

    {:reply, :ok, %{state | enabled: false}}
  end

  def handle_call({:set_drop_successful, value}, _from, state) do
    {:reply, :ok, %{state | drop_successful: value}}
  end

  def handle_call(:drop_successful?, _from, state) do
    {:reply, state.drop_successful, state}
  end

  # -- Event handlers (matching actual PubSub shapes from engine) --

  @impl true
  def handle_info({:process_instance_started, id, business_key, tenant_id, start_data}, state) do
    entry = %{
      id: id,
      process_name: Map.get(start_data, :process_name),
      business_key: business_key,
      tenant_id: tenant_id,
      parent_id: Map.get(start_data, :parent_id),
      state: :running,
      successful: false,
      tokens: [],
      started_at: DateTime.utc_now()
    }

    :ets.insert(@table, {id, entry})
    {:noreply, state}
  end

  def handle_info({:process_instance_completed, id, _business_key, _tenant_id, _completion_data}, state) do
    update_instance(id, fn entry ->
      %{entry | state: :completed, successful: true, completed_at: DateTime.utc_now()}
    end)

    if state.drop_successful do
      :ets.delete(@table, id)
    end

    {:noreply, state}
  end

  def handle_info({:process_instance_terminated, id, _business_key, _tenant_id, reason}, state) do
    update_instance(id, fn entry ->
      %{entry |
        state: :terminated,
        successful: false,
        termination_reason: reason,
        completed_at: DateTime.utc_now()
      }
    end)

    {:noreply, state}
  end

  def handle_info({:process_instance_resumed, _id}, state) do
    {:noreply, state}
  end

  def handle_info({:external_task_created, _id, _bk, _tenant, _task_id, _kind, _params, _key}, state) do
    {:noreply, state}
  end

  def handle_info({:external_task_completed, _id, _task_id, _success}, state) do
    {:noreply, state}
  end

  def handle_info({:start_not_found, info}, state) do
    :ets.insert(@errors_table, {:start_not_found, info})
    {:noreply, state}
  end

  def handle_info({:already_running, info}, state) do
    :ets.insert(@errors_table, {:already_running, info})
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- Helpers --

  defp update_instance(id, fun) do
    case :ets.lookup(@table, id) do
      [{_key, entry}] ->
        :ets.insert(@table, {id, fun.(entry)})

      [] ->
        :ok
    end
  end
end
