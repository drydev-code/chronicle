defmodule DryDev.Workflow.Engine.EvictionManager do
  @moduledoc """
  Periodic background process that scans for evictable process instances
  and evicts them to free memory.

  An instance is evictable when:
  - instance_state == :waiting
  - pin_state == :not_pinned
  - Idle time exceeds the configured threshold

  Configuration (in :drydev_workflow, :eviction):
  - enabled: boolean (default: false)
  - idle_threshold_ms: how long waiting before eligible (default: 300_000 = 5 min)
  - scan_interval_ms: how often to scan (default: 60_000 = 1 min)
  - max_resident: optional cap on resident instances (default: nil = unlimited)
  """
  use GenServer
  require Logger

  alias DryDev.Workflow.Engine.{Instance, InstanceLoadCell}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    config = get_config()

    state = %{
      enabled: config.enabled,
      idle_threshold_ms: config.idle_threshold_ms,
      scan_interval_ms: config.scan_interval_ms,
      max_resident: config.max_resident,
      # ETS table tracking evicted instance metadata
      evicted_count: 0,
      last_scan_at: nil
    }

    if state.enabled do
      schedule_scan(state.scan_interval_ms)
      Logger.info("EvictionManager started: threshold=#{state.idle_threshold_ms}ms, interval=#{state.scan_interval_ms}ms")
    else
      Logger.info("EvictionManager started (disabled)")
    end

    {:ok, state}
  end

  # --- Public API ---

  @doc "Enable or disable eviction at runtime."
  def set_enabled(enabled) do
    GenServer.call(__MODULE__, {:set_enabled, enabled})
  end

  @doc "Trigger an immediate eviction scan."
  def scan_now do
    GenServer.cast(__MODULE__, :scan_now)
  end

  @doc "Get eviction stats."
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  # --- GenServer Callbacks ---

  @impl true
  def handle_call({:set_enabled, enabled}, _from, state) do
    if enabled and not state.enabled do
      schedule_scan(state.scan_interval_ms)
    end

    {:reply, :ok, %{state | enabled: enabled}}
  end

  def handle_call(:stats, _from, state) do
    {:reply, %{
      enabled: state.enabled,
      evicted_count: state.evicted_count,
      last_scan_at: state.last_scan_at,
      idle_threshold_ms: state.idle_threshold_ms,
      scan_interval_ms: state.scan_interval_ms
    }, state}
  end

  @impl true
  def handle_cast(:scan_now, state) do
    state = do_scan(state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:scan, state) do
    state = if state.enabled do
      do_scan(state)
    else
      state
    end

    if state.enabled do
      schedule_scan(state.scan_interval_ms)
    end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Internal ---

  defp do_scan(state) do
    children = DynamicSupervisor.which_children(DryDev.Workflow.Engine.InstanceSupervisor)
    instance_pids = for {:undefined, pid, :worker, _} <- children, is_pid(pid), do: pid

    evicted =
      instance_pids
      |> Enum.filter(&evictable?/1)
      |> Enum.reduce(0, fn pid, count ->
        case try_evict_instance(pid) do
          :ok -> count + 1
          :error -> count
        end
      end)

    now = System.system_time(:millisecond)

    if evicted > 0 do
      Logger.info("EvictionManager: evicted #{evicted} instance(s)")
    end

    %{state |
      evicted_count: state.evicted_count + evicted,
      last_scan_at: now
    }
  end

  defp evictable?(pid) do
    try do
      state = Instance.get_state(pid)
      state.instance_state == :waiting and state.pin_state == :not_pinned
    catch
      :exit, _ -> false
    end
  end

  defp try_evict_instance(pid) do
    try do
      instance_state = Instance.get_state(pid)
      id = instance_state.id
      tenant_id = instance_state.tenant_id
      business_key = instance_state.business_key

      # Check if a LoadCell already exists
      case InstanceLoadCell.lookup(tenant_id, id) do
        {:ok, cell_pid} ->
          # LoadCell exists — trigger eviction through it
          case InstanceLoadCell.evict(cell_pid) do
            :ok -> :ok
            {:error, _} -> :error
          end

        {:error, :not_found} ->
          # No LoadCell yet — create one and evict
          {:ok, cell_pid} = InstanceLoadCell.start_link({id, tenant_id, business_key, pid})
          case InstanceLoadCell.evict(cell_pid) do
            :ok -> :ok
            {:error, _} ->
              GenServer.stop(cell_pid, :normal)
              :error
          end
      end
    catch
      :exit, _ -> :error
    end
  end

  defp schedule_scan(interval_ms) do
    Process.send_after(self(), :scan, interval_ms)
  end

  defp get_config do
    config = Application.get_env(:drydev_workflow, :eviction, [])
    %{
      enabled: Keyword.get(config, :enabled, false),
      idle_threshold_ms: Keyword.get(config, :idle_threshold_ms, 300_000),
      scan_interval_ms: Keyword.get(config, :scan_interval_ms, 60_000),
      max_resident: Keyword.get(config, :max_resident, nil)
    }
  end
end
