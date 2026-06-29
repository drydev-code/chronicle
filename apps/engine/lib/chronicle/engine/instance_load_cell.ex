defmodule Chronicle.Engine.InstanceLoadCell do
  @moduledoc """
  Lightweight proxy that manages the lifecycle of a process instance between
  resident (in-memory GenServer) and evicted (handles-only) states.

  State machine:
    :resident -> :evicting -> :evicted -> :restore_requested -> :restoring -> :resident

  When resident, messages pass through to the Instance GenServer directly.
  When evicted, incoming wake-up events are queued and trigger a restore from
  the event store. After restore completes, the mailbox is drained into the
  new Instance GenServer.

  State transition logic lives in `InstanceLoadCell.StateMachine`.
  Eviction/restore operations live in `InstanceLoadCell.Lifecycle`.
  """
  # :transient — a cell is removed (not respawned) when it stops :normal (its instance finished
  # and was cleaned up); a crash still restarts it so the restore path can recover the instance.
  use GenServer, restart: :transient
  require Logger

  alias Chronicle.Engine.Instance
  alias __MODULE__.{Lifecycle, StateMachine}

  @type cell_state :: :resident | :evicting | :evicted | :restore_requested | :restoring

  defstruct [
    :instance_id,
    :tenant_id,
    :business_key,
    :instance_pid,
    cell_state: :resident,
    waiting_handles: [],
    mailbox: :queue.new(),
    timer_refs: %{},
    # Restore self-healing: restore_ref tags the in-flight (or backoff-scheduled) restore so a
    # stale crash/timeout cast can't reset a cell that already restored; non-nil also means "a
    # restore is active or scheduled" so cycling wakes don't bypass the backoff. restore_attempts
    # drives exponential jittered backoff and resets on success.
    restore_ref: nil,
    restore_attempts: 0
  ]

  # --- Public API ---

  def start_link({instance_id, tenant_id, business_key, instance_pid}) do
    GenServer.start_link(__MODULE__, {instance_id, tenant_id, business_key, instance_pid},
      name: via(tenant_id, instance_id)
    )
  end

  @doc "Look up a load cell by tenant and instance ID."
  def lookup(tenant_id, instance_id) do
    case Registry.lookup(:load_cells, {tenant_id, instance_id}) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end

  @doc "Evict the instance from memory, keeping only waiting handles."
  def evict(cell_pid) do
    GenServer.call(cell_pid, :evict, 30_000)
  end

  @doc "Check if the instance is currently evicted."
  def evicted?(cell_pid) do
    GenServer.call(cell_pid, :evicted?)
  end

  @doc """
  Is `task_id` still an OPEN external task on this (evicted) instance? Checks the
  waiting handles captured at eviction — lets the DeliveryReconciler safely re-drive a
  stuck task for an evicted instance (whose reply was lost on the bus) without
  restoring it. Returns false if not currently evicted (handles are only populated
  while evicted; a resident instance is queried directly via the Instance).
  """
  def external_task_open?(cell_pid, task_id) do
    GenServer.call(cell_pid, {:external_task_open?, task_id})
  catch
    _, _ -> false
  end

  @doc "Get cell info for diagnostics."
  def inspect_cell(cell_pid) do
    GenServer.call(cell_pid, :inspect_cell)
  end

  @doc """
  Safety net for stranded cells. A cell that is `:evicted` with NO waiting handles can never be
  woken (nothing routes a wake to it). The `do_evict` guard prevents creating such cells, but if
  one ever forms via any path this triggers a restore so the (mid-transition) instance can advance
  or finish. No-op unless genuinely stranded.
  """
  def recover_if_stranded(cell_pid), do: GenServer.cast(cell_pid, :recover_if_stranded)

  defp via(tenant_id, instance_id) do
    {:via, Registry, {:load_cells, {tenant_id, instance_id}}}
  end

  # --- GenServer Callbacks ---

  @impl true
  def init({instance_id, tenant_id, business_key, instance_pid}) do
    Process.monitor(instance_pid)

    state = %__MODULE__{
      instance_id: instance_id,
      tenant_id: tenant_id,
      business_key: business_key,
      instance_pid: instance_pid,
      cell_state: :resident
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:evict, _from, state) do
    if StateMachine.evictable?(state.cell_state) do
      case Lifecycle.do_evict(state) do
        {:ok, new_state} -> {:reply, :ok, new_state}
        {:error, reason} -> {:reply, {:error, reason}, state}
      end
    else
      {:reply, {:error, {:invalid_state, state.cell_state}}, state}
    end
  end

  def handle_call(:evicted?, _from, state) do
    {:reply, state.cell_state == :evicted, state}
  end

  def handle_call({:external_task_open?, task_id}, _from, state) do
    open? =
      Enum.any?(state.waiting_handles, fn
        %Chronicle.Engine.WaitingHandle.ExternalTask{task_id: ^task_id} -> true
        _ -> false
      end)

    {:reply, open?, state}
  end

  def handle_call(:inspect_cell, _from, state) do
    info = %{
      instance_id: state.instance_id,
      tenant_id: state.tenant_id,
      cell_state: state.cell_state,
      mailbox_size: :queue.len(state.mailbox),
      waiting_handles: length(state.waiting_handles),
      has_instance_pid: state.instance_pid != nil
    }
    {:reply, info, state}
  end

  # --- Wake-up events ---

  @impl true
  def handle_cast({:wake, :external_task_complete, task_id, payload, result}, state) do
    handle_wake_event({:external_task_complete, task_id, payload, result}, state)
  end

  def handle_cast({:wake, :external_task_error, task_id, error, retry?, backoff_ms}, state) do
    handle_wake_event({:external_task_error, task_id, error, retry?, backoff_ms}, state)
  end

  def handle_cast({:wake, :external_task_cancel, task_id, reason, continuation_node_id}, state) do
    handle_wake_event({:external_task_cancel, task_id, reason, continuation_node_id}, state)
  end

  def handle_cast({:wake, :message, message_name, payload}, state) do
    handle_wake_event({:message, message_name, payload}, state)
  end

  def handle_cast({:wake, :signal, signal_name}, state) do
    handle_wake_event({:signal, signal_name}, state)
  end

  def handle_cast({:wake, :child_completed, child_id, context, successful}, state) do
    handle_wake_event({:child_completed, child_id, context, successful}, state)
  end

  # --- Restore completion ---

  def handle_cast({:restore_completed, ref, new_pid}, state) do
    if ref == state.restore_ref and StateMachine.restore_completable?(state.cell_state) do
      Process.monitor(new_pid)
      # Evicted message/signal waits routed to this cell while evicted; the now-resident Instance
      # re-registered its own :waits during restore, so retire the cell's :evicted_waits here.
      Lifecycle.unregister_evicted_waits(state.waiting_handles)
      drain_mailbox(new_pid, state.mailbox)
      Lifecycle.cancel_evicted_timers(state)

      Logger.info("InstanceLoadCell #{state.instance_id}: Restore completed, draining #{:queue.len(state.mailbox)} queued messages")

      {:noreply, %{state |
        cell_state: :resident,
        instance_pid: new_pid,
        waiting_handles: [],
        mailbox: :queue.new(),
        timer_refs: %{},
        restore_ref: nil,
        restore_attempts: 0
      }}
    else
      # Stale completion from a superseded attempt (or cell already resident/evicted) — ignore.
      {:noreply, state}
    end
  end

  # Restore failed (transient event-store read / instance start error, or a RAISED restore Task).
  # Reset to :evicted and schedule a jittered exponential-backoff retry. We keep restore_ref set
  # (non-nil = "restore pending") so cycling wakes during the backoff only QUEUE (handle_wake_event
  # won't re-trigger) — the scheduled :retry_restore is the single re-trigger, bounding the retry
  # rate. The queued wakes + the inbox's at-least-once rows are preserved, never lost.
  def handle_cast({:restore_failed, ref, _reason}, state) do
    if ref == state.restore_ref do
      {:noreply, schedule_retry(state, ref)}
    else
      {:noreply, state}
    end
  end

  # Safety net (driven by EvictionManager's scan): an :evicted cell with no waiting handles is
  # unwakeable. Trigger a restore so the instance re-evaluates and advances/finishes. Guarded so
  # normal evicted cells (with handles) and in-flight restores are untouched.
  def handle_cast(:recover_if_stranded, state) do
    if state.cell_state == :evicted and state.waiting_handles == [] and state.restore_ref == nil do
      Logger.warning("InstanceLoadCell #{state.instance_id}: stranded (evicted, no waits) — restoring")
      {:noreply, start_or_schedule_restore(state)}
    else
      {:noreply, state}
    end
  end

  # --- Info handlers ---

  @impl true
  def handle_info({:evicted_timer_elapsed, token_id, timer_ref}, state) do
    handle_wake_event({:timer_elapsed, token_id, timer_ref}, state)
  end

  def handle_info({:DOWN, _ref, :process, pid, reason}, %{instance_pid: pid} = state) do
    case state.cell_state do
      :evicting ->
        {:noreply, state}

      # Instance finished and stopped itself cleanly -> tear the cell down too (no restart, no
      # restore). This is what frees a completed instance's footprint; without it cells leak.
      :resident when reason in [:normal, :shutdown] ->
        {:stop, :normal, state}

      :resident ->
        Logger.error("InstanceLoadCell #{state.instance_id}: Instance process crashed: #{inspect(reason)}")
        {:stop, {:instance_crashed, reason}, state}

      _ ->
        {:noreply, %{state | instance_pid: nil}}
    end
  end

  # Backoff-scheduled restore retry after a failure. Only act if still the current attempt and
  # still evicted; if a wake already re-residented us, or a newer attempt superseded this ref, the
  # send_after is stale and ignored. Retry only when there is queued work; otherwise clear
  # restore_ref so the next wake re-triggers fresh.
  def handle_info({:retry_restore, ref}, state) do
    cond do
      ref != state.restore_ref or state.cell_state != :evicted ->
        {:noreply, state}

      :queue.len(state.mailbox) > 0 ->
        {:noreply, start_or_schedule_restore(%{state | restore_ref: nil})}

      true ->
        # No pending work — settle. Reset attempts so a later restore starts fresh backoff.
        {:noreply, %{state | restore_ref: nil, restore_attempts: 0}}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # Acquire a restore slot and start the restore, or — if the governor is saturated — schedule a
  # backoff retry. Either way the invariant holds: restore_ref != nil ⟹ exactly one restore is
  # in flight OR one {:retry_restore, restore_ref} timer is pending. So a governor denial (even one
  # hit from a retry) can never strand the cell — there is always a pending re-trigger (codex review).
  defp start_or_schedule_restore(state) do
    ref = make_ref()

    case Lifecycle.trigger_restore(state, ref) do
      {:ok, new_state} -> new_state
      {:no_slot, new_state} -> schedule_retry(new_state, ref)
    end
  end

  # Reset to :evicted and arm exactly one backoff retry tagged with `ref`, kept as restore_ref.
  defp schedule_retry(state, ref) do
    attempts = state.restore_attempts + 1
    Process.send_after(self(), {:retry_restore, ref}, restore_backoff_ms(attempts))
    %{state | cell_state: :evicted, restore_ref: ref, restore_attempts: attempts}
  end

  # Exponential backoff with jitter, capped. Paces per-cell restore retries so a deterministic
  # replay failure or DB outage can't become a tight restore loop (codex review).
  defp restore_backoff_ms(attempts) do
    base = 100 * trunc(:math.pow(2, min(attempts, 6)))
    base + :rand.uniform(base)
  end

  # --- Internal ---

  defp handle_wake_event(msg, %{cell_state: :resident, instance_pid: pid} = state) when pid != nil do
    forward_to_instance(pid, msg)
    {:noreply, state}
  end

  defp handle_wake_event(msg, state) do
    new_mailbox = :queue.in(msg, state.mailbox)
    state = %{state | mailbox: new_mailbox}

    # Trigger a restore only when evicted AND no restore is already in-flight or backoff-scheduled
    # (restore_ref == nil). During a post-failure backoff restore_ref stays set, so cycling wakes
    # just queue here and the scheduled :retry_restore is the single re-trigger — no tight loop.
    state = if StateMachine.should_restore?(state.cell_state) and state.restore_ref == nil do
      start_or_schedule_restore(state)
    else
      state
    end

    {:noreply, state}
  end

  defp drain_mailbox(instance_pid, mailbox) do
    case :queue.out(mailbox) do
      {:empty, _} -> :ok
      {{:value, msg}, rest} ->
        forward_to_instance(instance_pid, msg)
        drain_mailbox(instance_pid, rest)
    end
  end

  defp forward_to_instance(pid, {:external_task_complete, task_id, payload, result}) do
    Instance.complete_external_task(pid, task_id, payload, result)
  end

  defp forward_to_instance(pid, {:external_task_error, task_id, error, retry?, backoff_ms}) do
    Instance.error_external_task(pid, task_id, error, retry?, backoff_ms)
  end

  defp forward_to_instance(pid, {:external_task_cancel, task_id, reason, continuation_node_id}) do
    Instance.cancel_external_task(pid, task_id, reason, continuation_node_id)
  end

  defp forward_to_instance(pid, {:message, name, payload}) do
    Instance.send_message(pid, name, payload)
  end

  defp forward_to_instance(pid, {:signal, name}) do
    Instance.send_signal(pid, name)
  end

  defp forward_to_instance(pid, {:child_completed, child_id, context, successful}) do
    GenServer.cast(pid, {:child_completed, child_id, context, successful})
  end

  defp forward_to_instance(pid, {:timer_elapsed, token_id, timer_ref}) do
    send(pid, {:timer_elapsed, token_id, timer_ref})
  end
end
