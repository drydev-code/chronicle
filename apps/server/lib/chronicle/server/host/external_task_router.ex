defmodule Chronicle.Server.Host.ExternalTaskRouter do
  @moduledoc """
  Routes external task lifecycle events between the engine, host handlers, and AMQP.

  Subscribes to:
  - engine:events   — routes task creation to the ExternalTasks.Handler for AMQP publishing
  - engine:external_tasks — routes AMQP responses back to Instance processes

  Maintains a task_id → {tenant_id, instance_id} map to look up instances on completion.
  """
  use GenServer
  require Logger

  alias Chronicle.Server.Host.ExternalTasks.Handler
  alias Chronicle.Engine.Instance
  alias Chronicle.Engine.InstanceLoadCell

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_) do
    Phoenix.PubSub.subscribe(Chronicle.PubSub, "engine:events")
    Phoenix.PubSub.subscribe(Chronicle.PubSub, "engine:external_tasks")
    {:ok, %{tasks: %{}}}
  end

  # -- Outbound: engine creates external task → publish to AMQP --

  @impl true
  def handle_info({:external_task_created, instance_id, business_key, tenant_id,
                   task_id, kind, payload, node_key, node_properties}, state) do
    event = %{
      instance_id: instance_id,
      business_key: business_key,
      tenant_id: tenant_id,
      task_id: task_id,
      kind: kind,
      payload: payload,
      node_key: node_key,
      properties: node_properties
    }

    try do
      Handler.handle_external_task(event)
    rescue
      e ->
        Logger.error("ExternalTaskRouter: failed to handle task #{task_id}: #{inspect(e)}")
    end

    # Track task for routing completions back
    Logger.info("ExternalTaskRouter: registered task #{task_id} -> instance #{instance_id} (tenant #{tenant_id})")
    tasks = Map.put(state.tasks, task_id, {tenant_id, instance_id})
    {:noreply, %{state | tasks: tasks}}
  end

  # -- Inbound: AMQP response → route to Instance --

  @impl true
  def handle_info({:task_completed, task_id, payload, result}, state) do
    Logger.info("ExternalTaskRouter: received task_completed for task_id=#{inspect(task_id)}, known_tasks=#{inspect(Map.keys(state.tasks))}")
    case Map.get(state.tasks, task_id) do
      {tenant_id, instance_id} ->
        Logger.info("ExternalTaskRouter: found task mapping -> instance #{instance_id}")
        route_to_instance_or_cell(tenant_id, instance_id,
          {:complete, task_id, payload, result})
        {:noreply, %{state | tasks: Map.delete(state.tasks, task_id)}}

      nil ->
        Logger.warning("ExternalTaskRouter: unknown task_id #{inspect(task_id)} completed (not in known tasks)")
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:task_failed, task_id, error, retry?, backoff_ms}, state) do
    case Map.get(state.tasks, task_id) do
      {tenant_id, instance_id} ->
        route_to_instance_or_cell(tenant_id, instance_id,
          {:error, task_id, error, retry?, backoff_ms})
        if retry? do
          {:noreply, state}
        else
          {:noreply, %{state | tasks: Map.delete(state.tasks, task_id)}}
        end

      nil ->
        Logger.warning("ExternalTaskRouter: unknown task_id #{task_id} failed")
        {:noreply, state}
    end
  end

  # Ignore other engine events
  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # --- Internal ---

  defp route_to_instance_or_cell(tenant_id, instance_id, {:complete, task_id, payload, result}) do
    case Instance.lookup(tenant_id, instance_id) do
      {:ok, pid} ->
        Logger.info("ExternalTaskRouter: found instance pid=#{inspect(pid)}, completing task")
        Instance.complete_external_task(pid, task_id, payload, result)
      _ ->
        # Instance may be evicted — try LoadCell
        case InstanceLoadCell.lookup(tenant_id, instance_id) do
          {:ok, cell_pid} ->
            Logger.info("ExternalTaskRouter: instance evicted, waking via LoadCell for task #{task_id}")
            GenServer.cast(cell_pid, {:wake, :external_task_complete, task_id, payload, result})
          _ ->
            Logger.warning("ExternalTaskRouter: instance #{instance_id} not found (resident or evicted) for task #{task_id}")
        end
    end
  end

  defp route_to_instance_or_cell(tenant_id, instance_id, {:error, task_id, error, retry?, backoff_ms}) do
    case Instance.lookup(tenant_id, instance_id) do
      {:ok, pid} ->
        Instance.error_external_task(pid, task_id, error, retry?, backoff_ms)
      _ ->
        case InstanceLoadCell.lookup(tenant_id, instance_id) do
          {:ok, cell_pid} ->
            Logger.info("ExternalTaskRouter: instance evicted, waking via LoadCell for failed task #{task_id}")
            GenServer.cast(cell_pid, {:wake, :external_task_error, task_id, error, retry?, backoff_ms})
          _ ->
            Logger.warning("ExternalTaskRouter: instance #{instance_id} not found for failed task #{task_id}")
        end
    end
  end
end
