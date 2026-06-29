defmodule Chronicle.Engine.EvictionManager do
  @moduledoc """
  Periodic background process that scans for evictable process instances
  and evicts them to free memory.

  An instance is evictable when:
  - instance_state == :waiting
  - pin_state == :not_pinned
  - Idle time exceeds the configured threshold

  Configuration (in :engine, :eviction):
  - enabled: boolean (default: false)
  - idle_threshold_ms: how long waiting before eligible (default: 300_000 = 5 min)
  - scan_interval_ms: how often to scan (default: 60_000 = 1 min)
  - max_resident: optional cap on resident instances (default: nil = unlimited)
  """
  use GenServer
  require Logger

  alias Chronicle.Engine.{Instance, InstanceLoadCell, PersistentData}
  alias Chronicle.Persistence.EventStore

  @zero_tenant "00000000-0000-0000-0000-000000000000"

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
    children = DynamicSupervisor.which_children(Chronicle.Engine.InstanceSupervisor)
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

    # Safety-net pass: recover any stranded cell (evicted with no waiting handles -> unwakeable).
    # The do_evict guard prevents creating these, but this self-heals any that form via any path
    # so the system never needs a manual restore/wake. Cheap: a cast per cell, no-op unless stranded.
    recover_stranded_cells()

    # Safety-net pass: recover ORPHANED active instances — persisted active in the event store but
    # with NO live process (neither resident nor a load cell). These form when an instance's process
    # is lost without a cell (e.g. dispatched an external task then its process vanished); the reply
    # can't route to a non-existent process and nothing restores it until reboot. Startup restoration
    # only runs at boot, so this is its mid-run equivalent: restore them resident so the router +
    # DeliveryReconciler can drive them to completion.
    recover_orphaned_actives()

    now = System.system_time(:millisecond)

    if evicted > 0 do
      Logger.info("EvictionManager: evicted #{evicted} instance(s)")
    end

    %{state |
      evicted_count: state.evicted_count + evicted,
      last_scan_at: now
    }
  end

  defp recover_stranded_cells do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(Chronicle.Engine.LoadCellSupervisor),
        is_pid(pid) do
      InstanceLoadCell.recover_if_stranded(pid)
    end
  catch
    _, _ -> :ok
  end

  # Restore active instances that have no live process. Pre-filtered cheaply on the (common)
  # zero tenant — a resident/celled instance there is skipped without a DB read; only candidates
  # are streamed, and the real tenant from the stream gates the actual restore so we never
  # double-start. {:already_started} from a concurrent start is harmless.
  defp recover_orphaned_actives do
    for id <- safe_list_active_ids(),
        Registry.lookup(:instances, {@zero_tenant, id}) == [],
        Registry.lookup(:load_cells, {@zero_tenant, id}) == [] do
      restore_orphan(id)
    end
  catch
    _, _ -> :ok
  end

  defp safe_list_active_ids do
    EventStore.list_active_ids()
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  defp restore_orphan(id) do
    # First stream resolves the tenant for the authoritative registry recheck. After confirming
    # the instance has no live process, RE-STREAM fresh immediately before start_child: if it
    # completed/terminated in the meantime its active row is gone, the fresh stream returns
    # :not_found and we skip — never restoring a finished instance from stale events (codex review).
    with {:ok, events0} <- EventStore.stream(id),
         tenant <- extract_tenant_id(events0),
         [] <- Registry.lookup(:instances, {tenant, id}),
         [] <- Registry.lookup(:load_cells, {tenant, id}),
         {:ok, events} <- EventStore.stream(id) do
      case DynamicSupervisor.start_child(
             Chronicle.Engine.InstanceSupervisor,
             {Instance, {:restore, id, tenant, events}}
           ) do
        {:ok, _} ->
          Logger.warning("EvictionManager: restored orphaned active instance #{id} (no live process)")

        _ ->
          :ok
      end
    else
      _ -> :ok
    end
  catch
    _, _ -> :ok
  end

  defp extract_tenant_id(events) do
    case Enum.find(events, &match?(%PersistentData.ProcessInstanceStart{}, &1)) do
      %PersistentData.ProcessInstanceStart{tenant: tenant} when not is_nil(tenant) -> tenant
      _ -> @zero_tenant
    end
  end

  defp evictable?(pid) do
    try do
      state = Instance.get_state(pid)

      state.instance_state == :waiting and state.pin_state == :not_pinned and
        not has_transient_wait?(state)
    catch
      :exit, _ -> false
    end
  end

  # Only ONE wait is unsafe to evict: :waiting_for_script. In-flight JS runs off the
  # GenServer in a pool and has NO persisted result yet, so replay-on-restore would
  # advance the token without its ScriptTask outputs (empty uuid -> onboard
  # Command.DeserializationFailed). All other waits (external task, message, signal,
  # timer, call, conditional, gateway) have durable persisted state and restore
  # exactly. Their replies/wakes are delivered losslessly to the evicted instance via
  # the load cell + inbox-retry-until-resident (see PssGateway.Engine.wake_evicted) —
  # so evicting them is safe AND necessary to bound memory under the bulk-migration
  # instance cascade. Script waits are millisecond-short, so deferring them costs
  # almost nothing.
  @no_evict_waits [:waiting_for_script]
  defp has_transient_wait?(state) do
    state.tokens
    |> Map.values()
    |> Enum.any?(fn t -> t.state in @no_evict_waits end)
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
          # No LoadCell yet — start one under the dedicated supervisor so the
          # cell survives EvictionManager crashes.
          case DynamicSupervisor.start_child(
                 Chronicle.Engine.LoadCellSupervisor,
                 {InstanceLoadCell, {id, tenant_id, business_key, pid}}
               ) do
            {:ok, cell_pid} ->
              case InstanceLoadCell.evict(cell_pid) do
                :ok ->
                  :ok

                {:error, _} ->
                  DynamicSupervisor.terminate_child(
                    Chronicle.Engine.LoadCellSupervisor,
                    cell_pid
                  )

                  :error
              end

            {:error, {:already_started, cell_pid}} ->
              case InstanceLoadCell.evict(cell_pid) do
                :ok -> :ok
                {:error, _} -> :error
              end

            {:error, _reason} ->
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
    config = Application.get_env(:engine, :eviction, [])
    %{
      enabled: Keyword.get(config, :enabled, false),
      idle_threshold_ms: Keyword.get(config, :idle_threshold_ms, 300_000),
      scan_interval_ms: Keyword.get(config, :scan_interval_ms, 60_000),
      max_resident: Keyword.get(config, :max_resident, nil)
    }
  end
end
