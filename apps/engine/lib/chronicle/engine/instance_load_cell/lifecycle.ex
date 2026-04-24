defmodule Chronicle.Engine.InstanceLoadCell.Lifecycle do
  @moduledoc """
  Side-effectful eviction and restore operations for InstanceLoadCell.

  Handles the actual work of evicting an instance (persisting events, stopping
  the GenServer, registering handles) and restoring it (loading from event store,
  starting a new Instance GenServer).
  """
  require Logger

  alias Chronicle.Engine.{Instance, WaitingHandle}
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

    # Unregister evicted waits before restore (Instance will re-register its own)
    unregister_evicted_waits(state.waiting_handles)

    Task.start(fn ->
      case EventStore.stream(instance_id) do
        {:ok, events} ->
          case DynamicSupervisor.start_child(
            Chronicle.Engine.InstanceSupervisor,
            {Instance, {:restore, instance_id, tenant_id, events}}
          ) do
            {:ok, pid} ->
              GenServer.cast(cell_pid, {:restore_completed, pid})
            {:error, reason} ->
              Logger.error("InstanceLoadCell #{instance_id}: Restore failed: #{inspect(reason)}")
          end

        {:error, reason} ->
          Logger.error("InstanceLoadCell #{instance_id}: Cannot load events: #{inspect(reason)}")
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

    # Message wait handles
    msg_handles = Enum.flat_map(instance_state.message_waits, fn {name, token_ids} ->
      Enum.map(List.wrap(token_ids), fn token_id ->
        %WaitingHandle.Message{
          instance_id: id,
          tenant_id: tenant,
          message_name: name,
          business_key: instance_state.business_key,
          token_id: token_id
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
    timer_handles = Enum.map(instance_state.timer_refs, fn {ref, token_id} ->
      remaining = case Process.read_timer(ref) do
        false -> 0
        ms -> ms
      end

      %WaitingHandle.Timer{
        instance_id: id,
        tenant_id: tenant,
        token_id: token_id,
        trigger_at: now_ms + remaining
      }
    end)

    ext_handles ++ msg_handles ++ sig_handles ++ call_handles ++ timer_handles
  end

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

  defp register_evicted_timers(handles, _instance_id) do
    now_ms = System.system_time(:millisecond)

    handles
    |> Enum.filter(&match?(%WaitingHandle.Timer{}, &1))
    |> Enum.reduce(%{}, fn timer_handle, refs ->
      remaining_ms = if timer_handle.trigger_at do
        max(timer_handle.trigger_at - now_ms, 0)
      else
        0
      end

      timer_ref = make_ref()
      Process.send_after(self(), {:evicted_timer_elapsed, timer_handle.token_id, timer_ref}, remaining_ms)
      Map.put(refs, timer_ref, timer_handle.token_id)
    end)
  end

  defp register_evicted_waits(handles, cell_pid) do
    Enum.each(handles, fn
      %WaitingHandle.Message{} = h ->
        Registry.register(:evicted_waits, {h.tenant_id, :message, h.message_name, h.business_key}, cell_pid)
      %WaitingHandle.Signal{} = h ->
        Registry.register(:evicted_waits, {h.tenant_id, :signal, h.signal_name}, cell_pid)
      _ -> :ok
    end)
  end

  defp unregister_evicted_waits(handles) do
    Enum.each(handles, fn
      %WaitingHandle.Message{} = h ->
        Registry.unregister(:evicted_waits, {h.tenant_id, :message, h.message_name, h.business_key})
      %WaitingHandle.Signal{} = h ->
        Registry.unregister(:evicted_waits, {h.tenant_id, :signal, h.signal_name})
      _ -> :ok
    end)
  end
end
