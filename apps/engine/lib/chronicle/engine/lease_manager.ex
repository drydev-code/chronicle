defmodule Chronicle.Engine.LeaseManager do
  @moduledoc """
  Periodic background process that keeps instance ownership leases healthy
  across a multi-pod deployment (feature 3b, phase 2). Sibling of
  `Chronicle.Engine.EvictionManager`.

  Three jobs, all expressed as ONE scan over the active-instance table:

    * **Boot scan / orphan adoption** — an active row that is currently unowned
      (`owner_node IS NULL`) is an orphan: the pod that used to drive it is gone
      (crashed without releasing, or never acquired because the lease layer was
      enabled after it started). Acquire it and restore the instance here.
    * **Expired-lease steal (dead owner)** — an active row whose `lease_expiry`
      has passed is owned by a pod that stopped renewing (it died, or was
      partitioned). `InstanceLease.acquire/3` treats unowned AND expired
      identically (its CAS WHERE is `owner_node IS NULL OR lease_expiry < NOW`),
      so the SAME acquire path steals it; the fence epoch is bumped past the dead
      owner so any zombie write it later attempts is rejected.

  An instance this pod already drives (resident `Instance` registered, or an
  evicted `InstanceLoadCell` that is renewing the lease for it) is skipped — we
  never re-acquire what we already own, and a live peer's row is `:contended`
  and left alone.

  **N=1 / disabled invariant.** Dormant when `LeaseConfig.enabled?/0` is false
  (default / tests): `init/1` schedules no scan and the process just sits idle,
  so the existing suite is unaffected. At N=1 with the lease enabled, the single
  pod acquired every row it restored at boot (`Chronicle.Supervisor`), so the
  scan finds nothing unowned or expired and adopts nothing — a no-op.
  """
  use GenServer
  require Logger

  alias Chronicle.Engine.{Instance, InstanceLoadCell, LeaseConfig, NodeIdentity, PersistentData}
  alias Chronicle.Persistence.{EventStore, InstanceLease}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    enabled = LeaseConfig.enabled?()

    state = %{
      enabled: enabled,
      scan_interval_ms: LeaseConfig.scan_interval_ms(),
      adopted_count: 0,
      last_scan_at: nil
    }

    if enabled do
      schedule_scan(state.scan_interval_ms)
      Logger.info("LeaseManager started: scan_interval=#{state.scan_interval_ms}ms")
    else
      Logger.info("LeaseManager started (disabled)")
    end

    {:ok, state}
  end

  # --- Public API ---

  @doc "Trigger an immediate adoption scan and return the count adopted/stolen."
  def scan_now do
    GenServer.call(__MODULE__, :scan_now)
  end

  @doc "Get lease-manager stats."
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @doc """
  Graceful drain for a clean pod shutdown (feature 3b, phase 4).

  Releases every ownership lease this pod currently holds so a freshly-started
  pod can adopt the instances IMMEDIATELY (without waiting out the TTL), and
  without double-driving (the fence still guards any in-flight write). For each
  locally-owned instance — resident `Instance`s AND evicted `InstanceLoadCell`s
  — finish the in-flight cycle, flush, and `InstanceLease.release`:

    * resident: `Instance.drain/1` (sync call) waits behind any queued cycle,
      flushes, then releases the lease it holds;
    * evicted: `InstanceLoadCell.drain/1` releases the lease the cell was
      renewing on the evicted instance's behalf.

  A resident instance that also has a `:resident` load cell is covered by the
  Instance drain; the cell drain is a no-op there, so there is no double-release.

  Safe and idempotent at N=1 / lease-disabled: every local actor holds
  `:no_fence`, so each drain is a flush-only no-op and no lease is released
  (there is none). This is meant to be called from the host application's
  `prep_stop` AFTER AMQP consumption has been cancelled, so no new work arrives
  mid-drain. Returns `{:ok, released_count}`.
  """
  @spec drain() :: {:ok, non_neg_integer()}
  def drain do
    instance_pids = registry_pids(:instances)
    cell_pids = registry_pids(:load_cells)

    Enum.each(instance_pids, fn pid -> safe_drain(pid, &Instance.drain/1) end)
    Enum.each(cell_pids, fn pid -> safe_drain(pid, &InstanceLoadCell.drain/1) end)

    released = length(instance_pids) + length(cell_pids)

    if released > 0 do
      Logger.info("LeaseManager.drain: drained #{length(instance_pids)} resident + #{length(cell_pids)} evicted local actor(s)")
    end

    {:ok, released}
  end

  defp registry_pids(name) do
    Registry.select(name, [{{:_, :"$1", :_}, [], [:"$1"]}])
  rescue
    # Registry not started (e.g. engine not mounted) — nothing local to drain.
    _ -> []
  end

  defp safe_drain(pid, fun) do
    if Process.alive?(pid), do: fun.(pid)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # --- GenServer Callbacks ---

  @impl true
  def handle_call(:scan_now, _from, state) do
    {adopted, state} = do_scan(state)
    {:reply, {:ok, adopted}, state}
  end

  def handle_call(:stats, _from, state) do
    {:reply,
     %{
       enabled: state.enabled,
       adopted_count: state.adopted_count,
       last_scan_at: state.last_scan_at,
       scan_interval_ms: state.scan_interval_ms
     }, state}
  end

  @impl true
  def handle_info(:scan, state) do
    {_adopted, state} =
      if state.enabled do
        do_scan(state)
      else
        {0, state}
      end

    if state.enabled do
      schedule_scan(state.scan_interval_ms)
    end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Internal ---

  defp do_scan(state) do
    node = NodeIdentity.node_id()
    ttl = LeaseConfig.ttl_ms()

    adopted =
      EventStore.list_active_ids()
      |> Enum.reject(&driven_locally?/1)
      |> Enum.reduce(0, fn instance_id, count ->
        case adopt(instance_id, node, ttl) do
          {:ok, _id} -> count + 1
          _ -> count
        end
      end)

    now = System.system_time(:millisecond)

    if adopted > 0 do
      Logger.info("LeaseManager: adopted/stole #{adopted} instance(s)")
    end

    {adopted, %{state | adopted_count: state.adopted_count + adopted, last_scan_at: now}}
  end

  # An instance is already driven by THIS pod when it is resident (Instance
  # registered) OR sitting as an evicted load cell (which renews the lease for
  # it). Either way we must not re-acquire or double-restore it. We cannot know
  # the tenant from the id alone, so probe both registries by value.
  defp driven_locally?(instance_id) do
    instance_registered?(instance_id) or cell_registered?(instance_id)
  end

  defp instance_registered?(instance_id) do
    Registry.select(:instances, [
      {{{:_, instance_id}, :_, :_}, [], [true]}
    ]) != []
  end

  defp cell_registered?(instance_id) do
    Registry.select(:load_cells, [
      {{{:_, instance_id}, :_, :_}, [], [true]}
    ]) != []
  end

  # Acquire (unowned/expired) then restore. `:contended` means a live peer holds
  # it — leave it. The acquire CAS is the safety boundary: only the winner's
  # restore proceeds, and it fences with the freshly-bumped epoch.
  defp adopt(instance_id, node, ttl) do
    case InstanceLease.acquire(instance_id, node, ttl) do
      {:ok, epoch} -> restore(instance_id, node, epoch)
      :contended -> :contended
      {:error, :not_found} -> {:error, instance_id}
    end
  end

  defp restore(instance_id, node, epoch) do
    fence = InstanceLease.fence(node, epoch)

    case EventStore.stream(instance_id) do
      {:ok, events} ->
        if Enum.any?(events, &match?(%PersistentData.Unknown{}, &1)) do
          # FAIL-CLOSED, same contract as Supervisor.restore_instance: an event
          # this engine version cannot decode means a newer pod's instance —
          # refuse to drive it from a truncated replay. We already won the
          # lease; release it so the compatible pod can re-acquire instead of
          # waiting out the TTL.
          Logger.warning(
            "LeaseManager: instance #{instance_id} carries an unknown future event — refusing to adopt; releasing lease"
          )

          InstanceLease.release(instance_id, NodeIdentity.node_id(), epoch)
          {:error, instance_id}
        else
          tenant_id = extract_tenant_id(events)

          case DynamicSupervisor.start_child(
                 Chronicle.Engine.InstanceSupervisor,
                 {Instance, {:restore, instance_id, tenant_id, events, fence}}
               ) do
            {:ok, _pid} ->
              {:ok, instance_id}

            {:error, {:already_started, _pid}} ->
              # Lost a race to a concurrent restore (e.g. an evicted cell woke);
              # the other path owns it now. Not an adoption.
              :contended

            {:error, reason} ->
              Logger.error(
                "LeaseManager: failed to restore adopted instance #{instance_id}: #{inspect(reason)}"
              )

              {:error, instance_id}
          end
        end

      {:error, :not_found} ->
        {:error, instance_id}
    end
  end

  defp extract_tenant_id(events) do
    case Enum.find(events, &match?(%PersistentData.ProcessInstanceStart{}, &1)) do
      %PersistentData.ProcessInstanceStart{tenant: tenant} when not is_nil(tenant) -> tenant
      _ -> "00000000-0000-0000-0000-000000000000"
    end
  end

  defp schedule_scan(interval_ms) do
    Process.send_after(self(), :scan, interval_ms)
  end
end
