defmodule Chronicle.Engine.InstanceLoadCell.Lifecycle do
  @moduledoc """
  Side-effectful eviction and restore operations for InstanceLoadCell.

  Handles the actual work of evicting an instance (persisting events, stopping
  the GenServer, registering handles) and restoring it (loading from event store,
  starting a new Instance GenServer).
  """
  require Logger

  alias Chronicle.Engine.{Instance, RestoreLimiter, WaitingHandle}
  alias Chronicle.Engine.Diagrams.Definition
  alias Chronicle.Engine.Nodes
  alias Chronicle.Persistence.EventStore

  @doc """
  Evict a resident instance from memory.

  Returns `{:ok, updated_state}` with cell_state set to :evicted,
  or `{:error, reason}` if the instance cannot be evicted.
  """
  def do_evict(state) do
    instance_pid = state.instance_pid

    try do
      instance_state = Instance.get_state(instance_pid)

      if instance_state.instance_state != :waiting or instance_state.pin_state != :not_pinned do
        {:error, :not_evictable}
      else
        state = %{state | cell_state: :evicting}

        # Extract waiting handles from instance state
        handles = extract_waiting_handles(instance_state)

        # Persist current events to DB (ensure nothing is lost). If this
        # fails we must NOT stop the instance — unflushed events would be
        # lost and the durable replay would be incomplete.
        case persist_events_sync(instance_state) do
          :ok ->
            # Stop the Instance GenServer
            GenServer.stop(instance_pid, :normal)

            # Register handles for wake-up routing
            timer_refs = register_evicted_timers(handles, state.instance_id)

            # Re-register message/signal handles in :waits registry for this LoadCell
            register_evicted_waits(handles, self())

            new_state = %{state |
              cell_state: :evicted,
              instance_pid: nil,
              waiting_handles: handles,
              timer_refs: timer_refs
            }

            Logger.info("InstanceLoadCell #{state.instance_id}: Evicted with #{length(handles)} waiting handles")
            {:ok, new_state}

          {:error, reason} ->
            Logger.error(
              "InstanceLoadCell #{state.instance_id}: Eviction aborted, persist failed: #{inspect(reason)}"
            )

            {:error, {:persist_failed, reason}}
        end
      end
    catch
      :exit, _ -> {:error, :instance_not_responding}
    end
  end

  @doc """
  Trigger an asynchronous restore from the event store.

  Updates cell_state from :evicted -> :restore_requested -> :restoring
  and spawns a Task to load events and start a new Instance.
  """
  def trigger_restore(state) do
    state = %{state | cell_state: :restore_requested}
    cell_pid = self()
    instance_id = state.instance_id
    tenant_id = state.tenant_id
    handles = state.waiting_handles

    Task.start(fn ->
      # Bound concurrent on-demand restores so a broadcast wake on an :evicted
      # boot does not stampede InstanceSupervisor. No-op (returns immediately)
      # when the limiter is unbounded, i.e. on the default :resident path.
      RestoreLimiter.acquire()

      # Unregister evicted waits ONLY now that a permit is held and the restore is
      # actually materialising (Instance will re-register its own). Under a low
      # concurrency cap a cell can sit QUEUED in `acquire/0` for a while; doing the
      # unregister before then (or before the Task ran at all) would make this
      # instance's waits VANISH from `:evicted_waits` while still only queued — a
      # concurrent trigger in that window would find no waiter and be dropped. The
      # cell already de-dups in `:restoring`, so a redundant trigger here is a safe
      # no-op; a dropped one is a lost wake. Keep waits visible until restore starts.
      #
      # The rows were registered FROM the cell process (cell `init`/`do_evict` ran
      # `register_evicted_waits(handles, self())`), so `Registry.unregister` only
      # removes them when called BY that same owner process. Running it here in the
      # restore Task would be a silent no-op — the rows would leak forever. Cast the
      # unregister back to the cell so it drops its OWN rows now that a permit is held.
      GenServer.cast(cell_pid, {:unregister_evicted_waits, handles})

      try do
        case EventStore.stream(instance_id) do
          {:ok, events} ->
            case DynamicSupervisor.start_child(
              Chronicle.Engine.InstanceSupervisor,
              {Instance, {:restore, instance_id, tenant_id, events}}
            ) do
              {:ok, pid} ->
                GenServer.cast(cell_pid, {:restore_completed, pid})
              {:error, {:already_started, pid}} ->
                GenServer.cast(cell_pid, {:restore_completed, pid})
              {:error, reason} ->
                Logger.error("InstanceLoadCell #{instance_id}: Restore failed: #{inspect(reason)}")
                # Reset to :evicted so the next queued wake re-triggers a restore —
                # a transient start failure must not strand the cell (and its reply).
                GenServer.cast(cell_pid, :restore_failed)
            end

          {:error, reason} ->
            Logger.error("InstanceLoadCell #{instance_id}: Cannot load events: #{inspect(reason)}")
            GenServer.cast(cell_pid, :restore_failed)
        end
      after
        RestoreLimiter.release()
      end
    end)

    %{state | cell_state: :restoring}
  end

  @doc "Cancel all evicted timer references."
  def cancel_evicted_timers(state) do
    Enum.each(state.timer_refs, fn {ref, _} ->
      Process.cancel_timer(ref)
    end)
  end

  # --- Private helpers ---

  defp extract_waiting_handles(instance_state) do
    id = instance_state.id
    tenant = instance_state.tenant_id

    # External task handles
    ext_handles = Enum.map(instance_state.external_tasks, fn {task_id, token_id} ->
      %WaitingHandle.ExternalTask{
        instance_id: id,
        tenant_id: tenant,
        task_id: task_id,
        token_id: token_id
      }
    end)

    # Message wait handles. Carry the durable wait_id (looked up from the live
    # wait_ids index) so the evicted-path delivery can name the resolved wait
    # occurrence on the durable ack.
    wait_ids = Map.get(instance_state, :wait_ids, %{})
    msg_handles = Enum.flat_map(instance_state.message_waits, fn {name, token_ids} ->
      Enum.map(List.wrap(token_ids), fn token_id ->
        %WaitingHandle.Message{
          instance_id: id,
          tenant_id: tenant,
          message_name: name,
          business_key: instance_state.business_key,
          token_id: token_id,
          # Carry the keyless opt-in so the evicted cell re-registers the
          # `:no_key` secondary index exactly like the resident `:waits`.
          keyless: message_wait_keyless?(instance_state, name, token_id),
          wait_id:
            Map.get(wait_ids, {:message, name, token_id}) ||
              Map.get(wait_ids, {:gateway, token_id})
        }
      end)
    end)

    # Signal wait handles
    sig_handles = Enum.flat_map(instance_state.signal_waits, fn {name, token_ids} ->
      Enum.map(List.wrap(token_ids), fn token_id ->
        %WaitingHandle.Signal{
          instance_id: id,
          tenant_id: tenant,
          signal_name: name,
          token_id: token_id
        }
      end)
    end)

    # Call wait handles
    call_handles = Enum.map(instance_state.call_wait_list, fn {child_id, token_id} ->
      %WaitingHandle.Call{
        instance_id: id,
        tenant_id: tenant,
        child_id: child_id,
        token_id: token_id
      }
    end)

    # Timer handles
    now_ms = System.system_time(:millisecond)
    timer_ref_ids = Map.get(instance_state, :timer_ref_ids, %{})
    timer_handles = Enum.map(instance_state.timer_refs, fn {ref, token_id} ->
      remaining = case Process.read_timer(ref) do
        false -> 0
        ms -> ms
      end

      %WaitingHandle.Timer{
        instance_id: id,
        tenant_id: tenant,
        token_id: token_id,
        trigger_at: now_ms + remaining,
        # Carry the DURABLE timer_id so the evicted cell's `send_after` fires the
        # same marker the resident path uses; a raw `make_ref()` marker would
        # leak a non-JSON-encodable Reference into `TimerElapsed.timer_id`.
        timer_ref: Map.get(timer_ref_ids, ref)
      }
    end)

    ext_handles ++ msg_handles ++ sig_handles ++ call_handles ++ timer_handles
  end

  # B'.5 keyless opt-in at eviction time. Mirror of event_replayer.ex
  # `message_wait_keyless?/3`: a message wait joins the `:no_key` secondary index
  # ONLY when its catch node carries `message.allow_keyless: true`. For an
  # event-gateway branch the token sits on the gateway node, so consult the
  # matching message CANDIDATE branch node (not `token.current_node`).
  defp message_wait_keyless?(instance_state, name, token_id) do
    definition = Map.get(instance_state, :definition)
    tokens = Map.get(instance_state, :tokens, %{})

    case definition && Map.get(tokens, token_id) do
      nil ->
        false

      token ->
        case Definition.get_node(definition, token.current_node) do
          %Nodes.Gateway{kind: :event_based} ->
            gateway_candidate_keyless?(definition, token, name)

          node ->
            node_message_keyless?(node)
        end
    end
  end

  defp gateway_candidate_keyless?(definition, token, name) do
    (token.context[:event_gateway_candidates] || [])
    |> List.wrap()
    |> Enum.filter(&(&1[:type] == :message and &1[:name] == name))
    |> Enum.any?(fn candidate ->
      definition
      |> Definition.get_node(candidate[:node_id])
      |> node_message_keyless?()
    end)
  end

  defp node_message_keyless?(nil), do: false
  defp node_message_keyless?(node), do: match?(%{allow_keyless: true}, Map.get(node, :message) || %{})

  # Flushes any unpersisted events to the EventStore.
  # Returns `:ok` if everything was already persisted or the append succeeded,
  # `{:error, reason}` otherwise. Callers MUST NOT proceed to stop the
  # instance when this returns an error — the unflushed events would be lost.
  defp persist_events_sync(instance_state) do
    total = length(instance_state.persistent_events)
    # Prefer the in-memory index the Instance maintains. Fall back to the
    # EventStore's persisted count in case an older (pre-index) state is
    # still in flight — this preserves the invariant that we only ever
    # append the delta and never re-send events already in the store.
    already_persisted =
      case Map.get(instance_state, :last_persisted_index) do
        idx when is_integer(idx) -> idx
        _ -> EventStore.current_sequence(instance_state.id)
      end

    pending =
      if already_persisted < total do
        Enum.drop(instance_state.persistent_events, already_persisted)
      else
        []
      end

    case pending do
      [] ->
        :ok

      events ->
        case EventStore.append_batch(instance_state.id, events) do
          {:ok, _} -> :ok
          :ok -> :ok
          {:error, reason} -> {:error, reason}
          other -> {:error, other}
        end
    end
  rescue
    e -> {:error, e}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  @doc """
  Arm process timers for each open `WaitingHandle.Timer` and return a
  `%{send_after_ref => token_id}` map (the `send_after_ref` is cancelable via
  `cancel_evicted_timers/1`). Called both at eviction time and by the
  evicted-from-inception `InstanceLoadCell` constructor on boot-restore.

  The fast-path `send_after` fires `{:evicted_timer_elapsed, token_id, marker,
  boundary_node_id}` where `marker` is the DURABLE `timer_id` (from
  `WaitingHandle.Timer.timer_ref`) — exactly the marker the resident path arms
  (`token_processor` sends `{:timer_elapsed, token, timer_id}`). The restored
  `Instance.resolve_timer_ref` then resolves it to a durable id, so the persisted
  `TimerElapsed.timer_id` is a JSON-encodable string, never a raw `make_ref()`
  Reference.

  `boundary_node_id` is `nil` for a plain intermediate-catch timer and the
  boundary node id for a boundary timer — carrying it lets the cell forward a
  boundary timer as `{:boundary_timer_elapsed, token, boundary_node_id, marker}`
  (the shape `Instance` and the resident `EventReplayer` use), so an evicted
  boundary timer wakes the boundary continuation and never the wrong (plain)
  `:timer_elapsed` handler.
  """
  def register_evicted_timers(handles, _instance_id) do
    now_ms = System.system_time(:millisecond)

    handles
    |> Enum.filter(&match?(%WaitingHandle.Timer{}, &1))
    |> Enum.reduce(%{}, fn timer_handle, refs ->
      remaining_ms = if timer_handle.trigger_at do
        max(timer_handle.trigger_at - now_ms, 0)
      else
        0
      end

      marker = timer_handle.timer_ref || timer_handle.token_id

      send_after_ref =
        Process.send_after(
          self(),
          {:evicted_timer_elapsed, timer_handle.token_id, marker, timer_handle.boundary_node_id},
          remaining_ms
        )

      Map.put(refs, send_after_ref, timer_handle.token_id)
    end)
  end

  @doc """
  Register message/signal/timer waits in the `:evicted_waits` registry. Called
  both at eviction time and by the evicted-from-inception `InstanceLoadCell`
  constructor on boot-restore.

  Value shapes:
    {tenant, :message, name, business_key} -> cell_pid
    {tenant, :message, name, :no_key}      -> cell_pid   (keyless catches only)
    {tenant, :signal, name}                -> cell_pid
    {tenant, :timer, instance_id, token_id, timer_id} ->
      {cell_pid, trigger_at, timer_id, boundary_node_id}

  A catch declared keyless (`h.keyless`) ALSO joins the opt-in
  `{tenant, :message, name, :no_key}` secondary index — mirroring the resident
  `:waits` registration (token_processor.ex `message_node_keyless?`) — so a
  nil-key inbound (gateway `correlate`/`evicted_wait_exists?` fall back to
  `:no_key`) can find a boot-restored keyless catch. Keyed catches keep only the
  `business_key` entry and never join `:no_key`.

  Timer entries carry `trigger_at` (epoch ms) so the durable `TimerSweeper` can
  decide a timer is due WITHOUT restoring the instance — `Process.send_after` is
  the fast path that dies with the cell, this registration is the crash-durable
  safety net the sweeper scans. Message/signal consumers (`Registry.dispatch`
  with explicit keys) never see timer keys, so this is isolated.
  """
  def register_evicted_waits(handles, cell_pid) do
    Enum.each(handles, fn
      %WaitingHandle.Message{} = h ->
        Registry.register(:evicted_waits, {h.tenant_id, :message, h.message_name, h.business_key}, cell_pid)

        if h.keyless do
          Registry.register(:evicted_waits, {h.tenant_id, :message, h.message_name, :no_key}, cell_pid)
        end
      %WaitingHandle.Signal{} = h ->
        Registry.register(:evicted_waits, {h.tenant_id, :signal, h.signal_name}, cell_pid)
      %WaitingHandle.Call{} = h ->
        # An EVICTED parent waiting on a child call is woken by a PUSH: the child
        # casts `{:wake, :child_completed, ...}` at its completion (Instance
        # `notify_parent_child_completed/5`). That cast is volatile — if the child
        # persists its own completion and then the process (or the parent cell)
        # crashes before the parent records its CallCompleted, the wake is LOST and
        # the parent deadlocks on a child that is already terminal. This durable row
        # is the crash-durable safety net the `CallReturnSweeper` scans: for a child
        # that is durably terminal but whose parent has not recorded the return, the
        # sweeper re-pokes this cell. The key carries `instance_id` (the parent) and
        # `child_id` so the sweeper can re-derive the exact wake; the child_id is a
        # UUID so it stays distinct. Message/signal/timer consumers select on their
        # own key shapes and never see `:call` rows, so this is isolated.
        Registry.register(
          :evicted_waits,
          {h.tenant_id, :call, h.instance_id, h.child_id},
          {cell_pid, h.token_id}
        )
      %WaitingHandle.Timer{} = h ->
        # Instance- AND timer-scoped key: `token_id` is per-instance (every flow's
        # first timer is token 1), so a bare `{tenant, :timer, token_id}` would
        # collide across instances; and a single token can own MORE THAN ONE timer
        # (e.g. an interrupting + a non-interrupting boundary timer on the same
        # activity token), so the key must also carry the DURABLE `timer_id` —
        # otherwise the two timers pile under one key and the sweeper can only
        # recover (and only ever distinguishes) one of them. The value carries
        # `timer_id` (so the sweeper forwards the exact JSON-safe marker, never the
        # token) and `boundary_node_id` (so a boundary timer the sweeper recovers is
        # forwarded as `{:boundary_timer_elapsed, ...}`, waking the boundary
        # continuation rather than the wrong plain `:timer_elapsed` handler).
        Registry.register(
          :evicted_waits,
          {h.tenant_id, :timer, h.instance_id, h.token_id, h.timer_ref},
          {cell_pid, h.trigger_at, h.timer_ref, h.boundary_node_id}
        )

      _ -> :ok
    end)
  end

  @doc """
  Idempotently RE-register this cell's `:evicted_waits` rows. MUST be called from
  the owning cell process.

  NEW-3: `trigger_restore` casts `{:unregister_evicted_waits, handles}` once a
  permit is held — this drops the durable `:evicted_waits` rows on the assumption
  the restored Instance will re-register its own. On a transient `:restore_failed`
  (event-store read / start_child error) the Instance never materialised, so those
  rows would be GONE and a future trigger would find no waiter (the instance is
  lost). Re-registering here keeps the cell reachable for the next wake.

  Idempotent: `:evicted_waits` is a `:duplicate` registry, so we `unregister`
  first (removes only this owner's rows; a no-op if already gone) before
  `register`, guaranteeing exactly one row per key regardless of how far the
  failed restore got.
  """
  def reregister_evicted_waits(handles, cell_pid) do
    unregister_evicted_waits(handles)
    register_evicted_waits(handles, cell_pid)
  end

  @doc """
  Unregister this cell's `:evicted_waits` rows. MUST be called from the cell
  process that registered them — `Registry.unregister` only removes entries owned
  by the calling process, so a no-op otherwise (see `trigger_restore`).
  """
  def unregister_evicted_waits(handles) do
    Enum.each(handles, fn
      %WaitingHandle.Message{} = h ->
        Registry.unregister(:evicted_waits, {h.tenant_id, :message, h.message_name, h.business_key})

        if h.keyless do
          Registry.unregister(:evicted_waits, {h.tenant_id, :message, h.message_name, :no_key})
        end
      %WaitingHandle.Signal{} = h ->
        Registry.unregister(:evicted_waits, {h.tenant_id, :signal, h.signal_name})
      %WaitingHandle.Call{} = h ->
        Registry.unregister(:evicted_waits, {h.tenant_id, :call, h.instance_id, h.child_id})
      %WaitingHandle.Timer{} = h ->
        Registry.unregister(:evicted_waits, {h.tenant_id, :timer, h.instance_id, h.token_id, h.timer_ref})
      _ -> :ok
    end)
  end
end
