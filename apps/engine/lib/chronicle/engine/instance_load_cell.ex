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
  use GenServer
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
    # pending_syncs: GenServer.from() refs awaiting a DURABLE delivery result while
    # the instance is restoring. Each is {from, command} where command is replayed
    # against the restored instance via a *sync* Instance call; the caller is replied
    # to ONLY after that call returns a persisted outcome. This is the evicted-path
    # durable-ack the retention store (and the reply ledger) settle on.
    pending_syncs: :queue.new(),
    timer_refs: %{}
  ]

  @sync_call_timeout 30_000

  # --- Public API ---

  def start_link({instance_id, tenant_id, business_key, instance_pid}) do
    GenServer.start_link(__MODULE__, {instance_id, tenant_id, business_key, instance_pid},
      name: via(tenant_id, instance_id)
    )
  end

  @doc """
  Start a load cell that is EVICTED from inception (no resident Instance ever
  existed in this process lifetime — used on boot-restore). `handles` is the list
  of open `WaitingHandle` structs reconstructed from the event stream. The cell's
  `init/1` lands directly in `:evicted` (no `Process.monitor`) and registers its
  waits + timers so wake-up routing works without first materialising an Instance.
  """
  def start_link({:evicted, instance_id, tenant_id, business_key, handles}) do
    GenServer.start_link(
      __MODULE__,
      {:evicted, instance_id, tenant_id, business_key, handles},
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

  @doc """
  Synchronously deliver a correlation message through the load cell, returning the
  DURABLE outcome (`{:matched, wait_ids}` / `:ignored` / `:boundary`).

  Resident: forwards straight to the Instance's `send_message_sync` (which persists
  the message outcome before replying). Evicted/restoring: the caller is parked, a
  restore is triggered, and the reply is sent ONLY after the restored instance has
  durably processed the message. The retention store records consumption only on this
  reply — never on the fire-and-forget `:wake` cast.
  """
  def deliver_message_sync(cell_pid, message_name, payload \\ %{}, timeout \\ @sync_call_timeout) do
    GenServer.call(cell_pid, {:sync_command, {:message, message_name, payload}}, timeout)
  end

  @doc """
  Synchronously deliver a signal through the load cell, returning the DURABLE
  outcome. Mirrors `deliver_message_sync`: resident forwards straight to the
  Instance's `send_signal_sync` (which persists before replying); evicted/restoring
  parks the caller, triggers a restore, and replies only after the restored instance
  has durably processed the signal.
  """
  def deliver_signal_sync(cell_pid, signal_name, timeout \\ @sync_call_timeout) do
    GenServer.call(cell_pid, {:sync_command, {:signal, signal_name}}, timeout)
  end

  @doc """
  Generic synchronous, durable-ack load-cell command. Covers message delivery AND
  external-task complete/error/cancel so the reply ledger settles (and the retention
  store consumes) only on a persisted result, on both the resident and evicted paths.

  `command` is one of:
    {:message, name, payload}
    {:external_task_complete, task_id, payload, result}
    {:external_task_error, task_id, error, retry?, backoff_ms}
    {:external_task_cancel, task_id, reason, continuation_node_id}
  """
  def command_sync(cell_pid, command, timeout \\ @sync_call_timeout) do
    GenServer.call(cell_pid, {:sync_command, command}, timeout)
  end

  @doc """
  Poke an evicted cell to fire a durable timer the `TimerSweeper` found elapsed.

  Fire-and-forget: the cell wakes the same way an `:evicted_timer_elapsed`
  message would, triggering an on-demand restore + token advance. Idempotent at
  the instance — if the token already moved on (e.g. the fast-path `send_after`
  already fired), `WaitRegistry.handle_timer_elapsed` ignores it. This is the
  crash-durability safety net for timers whose `send_after` died with the cell.

  `timer_id` is the DURABLE marker carried on the registry row, so the poke
  forwards the exact JSON-safe marker (never the cancelable `send_after`
  Reference, never a bare token that cannot tell two timers on one token apart).
  `boundary_node_id` is `nil` for a plain timer and the boundary node id for a
  boundary timer, so a boundary timer the sweeper recovers wakes the boundary
  continuation instead of the wrong plain `:timer_elapsed` handler.
  """
  def sweep_timer(cell_pid, token_id, timer_id \\ nil, boundary_node_id \\ nil) do
    GenServer.cast(cell_pid, {:sweep_timer, token_id, timer_id, boundary_node_id})
  end

  @doc """
  Poke an evicted parent cell to re-drive a child call-return the
  `CallReturnSweeper` found owed (child durably terminal, parent not yet
  recorded the return).

  Fire-and-forget: the cell wakes exactly as the child's volatile
  `{:wake, :child_completed, ...}` cast would (`Instance.notify_parent_child_completed/5`),
  triggering an on-demand restore + token advance. Idempotent at the instance —
  once the parent has recorded its `CallCompleted`, replay removes the child from
  `call_wait_list`, so `WaitRegistry.handle_child_completed` resolves
  `{:error, :not_found}` and no second `CallCompleted` is appended. This is the
  crash-durability safety net for the call return whose push cast died with the
  child (or the parent cell) before the parent persisted.

  `completion_context` is best-effort (`%{}` for a redrive): the child's
  in-memory completion_data is volatile and not reconstructable from its terminal
  stream, but recording the return + advancing the parent is the durable
  correctness property — a lost result variable is recoverable, a deadlocked
  parent is not.
  """
  def redrive_child_return(cell_pid, child_id, completion_context \\ %{}, successful \\ true) do
    GenServer.cast(cell_pid, {:wake, :child_completed, child_id, completion_context, successful})
  end

  @doc "Get cell info for diagnostics."
  def inspect_cell(cell_pid) do
    GenServer.call(cell_pid, :inspect_cell)
  end

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

  # Evicted-from-inception: no live Instance, no monitor. Land directly in
  # :evicted with the reconstructed handles, registering waits + timers so
  # wake-up events route through this cell (and trigger an on-demand restore).
  def init({:evicted, instance_id, tenant_id, business_key, handles}) do
    timer_refs = Lifecycle.register_evicted_timers(handles, instance_id)
    Lifecycle.register_evicted_waits(handles, self())

    state = %__MODULE__{
      instance_id: instance_id,
      tenant_id: tenant_id,
      business_key: business_key,
      instance_pid: nil,
      cell_state: :evicted,
      waiting_handles: handles,
      timer_refs: timer_refs
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

  def handle_call({:sync_command, command}, from, %{cell_state: :resident, instance_pid: pid} = state)
      when pid != nil do
    # Resident: deliver synchronously to the Instance, which persists the outcome
    # before replying. Run in a Task so the load cell is not blocked, and so a slow
    # instance call cannot deadlock the cell against its own monitors.
    forward_sync_to_instance(pid, command, from)
    {:noreply, state}
  end

  def handle_call({:sync_command, command}, from, state) do
    # Evicted/restoring: park the caller until the restored instance durably processes
    # the command. Trigger a restore if we are sitting in :evicted.
    state = %{state | pending_syncs: :queue.in({from, command}, state.pending_syncs)}

    state =
      if StateMachine.should_restore?(state.cell_state) do
        Lifecycle.trigger_restore(state)
      else
        state
      end

    {:noreply, state}
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

  # Durable-timer poke from the TimerSweeper: a registered timer's trigger_at has
  # passed and its fast-path send_after may have died with a previous cell. Reuse
  # the timer wake path. The sweeper carries the DURABLE timer_id and (when the
  # timer is a boundary timer) its boundary_node_id straight off the registry row,
  # so the poke targets the EXACT timer — two timers on one token each carry their
  # own marker and continuation. We never forward the cancelable send_after
  # Reference (it would leak a non-JSON-encodable Reference into the persisted
  # TimerElapsed.timer_id), and never a bare token (it cannot tell two timers
  # apart). Idempotent at the instance.
  def handle_cast({:sweep_timer, token_id, timer_id, boundary_node_id}, state) do
    # Prefer the marker the sweeper carried; fall back to resolving the durable
    # timer_id from the captured handle for older/direct callers. Resolving the
    # handle ALSO recovers the boundary_node_id when the caller did not supply one.
    handle =
      Enum.find(state.waiting_handles, fn
        %Chronicle.Engine.WaitingHandle.Timer{token_id: ^token_id, timer_ref: ^timer_id} ->
          not is_nil(timer_id)

        %Chronicle.Engine.WaitingHandle.Timer{token_id: ^token_id} ->
          is_nil(timer_id)

        _ ->
          false
      end)

    marker = timer_id || (handle && handle.timer_ref) || token_id
    boundary = boundary_node_id || (handle && handle.boundary_node_id)

    handle_wake_event(timer_wake(token_id, marker, boundary), state)
  end

  # Backward-compatible 1-arg poke (direct/legacy callers): resolve marker +
  # boundary metadata from the captured handle.
  def handle_cast({:sweep_timer, token_id}, state) do
    handle_cast({:sweep_timer, token_id, nil, nil}, state)
  end

  # --- Restore completion ---

  def handle_cast({:restore_completed, new_pid}, state) do
    if StateMachine.restore_completable?(state.cell_state) do
      Process.monitor(new_pid)
      drain_mailbox(new_pid, state.mailbox)
      # Drain parked sync callers AFTER the fire-and-forget mailbox so they observe a
      # fully-applied instance, replying each only on the restored instance's durable
      # result.
      drain_pending_syncs(new_pid, state.pending_syncs)
      Lifecycle.cancel_evicted_timers(state)

      Logger.info("InstanceLoadCell #{state.instance_id}: Restore completed, draining #{:queue.len(state.mailbox)} queued messages and #{:queue.len(state.pending_syncs)} sync callers")

      {:noreply, %{state |
        cell_state: :resident,
        instance_pid: new_pid,
        waiting_handles: [],
        mailbox: :queue.new(),
        pending_syncs: :queue.new(),
        timer_refs: %{}
      }}
    else
      {:noreply, state}
    end
  end

  # Restore failed (transient: event-store read or instance start error). Reset to
  # :evicted so a subsequent queued wake re-triggers the restore — the queued wakes
  # (and the inbox rows behind them) are preserved, never lost. Re-trigger now if any
  # wake is already waiting.
  def handle_cast(:restore_failed, state) do
    state = %{state | cell_state: :evicted}

    # NEW-3: `trigger_restore` unregistered this cell's `:evicted_waits` rows once
    # a permit was held (expecting the restored Instance to re-register its own).
    # The restore failed transiently, so the Instance never materialised — without
    # re-registering, a future message/signal/timer/call trigger would find no
    # waiter and the instance would be silently lost. Re-register (idempotently)
    # from THIS cell process so it stays reachable for the next wake. Done before a
    # possible re-trigger so the rows are present throughout.
    Lifecycle.reregister_evicted_waits(state.waiting_handles, self())

    state =
      if :queue.len(state.mailbox) > 0 or :queue.len(state.pending_syncs) > 0 do
        Lifecycle.trigger_restore(state)
      else
        state
      end

    {:noreply, state}
  end

  # Drop this cell's `:evicted_waits` rows. The restore Task casts this once it has
  # acquired the limiter permit (restore is materialising). It MUST run here in the
  # cell process — the rows were registered by the cell, and `Registry.unregister`
  # only removes entries owned by the calling process. The Instance re-registers its
  # own waits on restore, so these durable evicted rows are now stale.
  def handle_cast({:unregister_evicted_waits, handles}, state) do
    Lifecycle.unregister_evicted_waits(handles)
    {:noreply, state}
  end

  # --- Info handlers ---

  @impl true
  def handle_info({:evicted_timer_elapsed, token_id, timer_ref, boundary_node_id}, state) do
    handle_wake_event(timer_wake(token_id, timer_ref, boundary_node_id), state)
  end

  # Backward-compatible 3-element fast-path arm (plain, non-boundary timer).
  def handle_info({:evicted_timer_elapsed, token_id, timer_ref}, state) do
    handle_wake_event(timer_wake(token_id, timer_ref, nil), state)
  end

  def handle_info({:DOWN, _ref, :process, pid, reason}, %{instance_pid: pid} = state) do
    case state.cell_state do
      :evicting ->
        {:noreply, state}

      :resident ->
        Logger.error("InstanceLoadCell #{state.instance_id}: Instance process crashed: #{inspect(reason)}")
        {:stop, {:instance_crashed, reason}, state}

      _ ->
        {:noreply, %{state | instance_pid: nil}}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Internal ---

  defp handle_wake_event(msg, %{cell_state: :resident, instance_pid: pid} = state) when pid != nil do
    forward_to_instance(pid, msg)
    {:noreply, state}
  end

  defp handle_wake_event(msg, state) do
    new_mailbox = :queue.in(msg, state.mailbox)
    state = %{state | mailbox: new_mailbox}

    state = if StateMachine.should_restore?(state.cell_state) do
      Lifecycle.trigger_restore(state)
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

  # Replays each parked sync command against the restored instance and replies to the
  # original caller ONLY with the instance's durable result. Run per-caller in a Task
  # so the load cell stays responsive while the (synchronous) instance call runs.
  defp drain_pending_syncs(instance_pid, pending) do
    case :queue.out(pending) do
      {:empty, _} -> :ok
      {{:value, {from, command}}, rest} ->
        forward_sync_to_instance(instance_pid, command, from)
        drain_pending_syncs(instance_pid, rest)
    end
  end

  defp forward_sync_to_instance(instance_pid, command, from) do
    Task.start(fn ->
      reply =
        try do
          do_sync_command(instance_pid, command)
        catch
          kind, reason -> {:error, {kind, reason}}
        end

      GenServer.reply(from, reply)
    end)
  end

  defp do_sync_command(pid, {:message, name, payload}) do
    Instance.send_message_sync(pid, name, payload)
  end

  defp do_sync_command(pid, {:signal, name}) do
    Instance.send_signal_sync(pid, name)
  end

  defp do_sync_command(pid, {:external_task_complete, task_id, payload, result}) do
    Instance.complete_external_task_sync(pid, task_id, payload, result)
  end

  defp do_sync_command(pid, {:external_task_error, task_id, error, retry?, backoff_ms}) do
    Instance.error_external_task_sync(pid, task_id, error, retry?, backoff_ms)
  end

  defp do_sync_command(pid, {:external_task_cancel, task_id, reason, continuation_node_id}) do
    Instance.cancel_external_task_sync(pid, task_id, reason, continuation_node_id)
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

  # A boundary timer MUST reach the restored Instance as
  # `{:boundary_timer_elapsed, token, boundary_node_id, marker}` — the exact shape
  # the resident `EventReplayer` re-arms (event_replayer.ex ~1043) and that
  # `Instance.handle_info/2` routes to `handle_boundary_timer_elapsed`. Forwarding
  # it as a plain `:timer_elapsed` would wake the wrong continuation or be ignored.
  defp forward_to_instance(pid, {:boundary_timer_elapsed, token_id, boundary_node_id, timer_ref}) do
    send(pid, {:boundary_timer_elapsed, token_id, boundary_node_id, timer_ref})
  end

  # Build the wake tuple that flows through the mailbox queue and `forward_to_instance`:
  # a boundary timer (non-nil `boundary_node_id`) carries its boundary continuation;
  # a plain timer stays `{:timer_elapsed, ...}`.
  defp timer_wake(token_id, marker, nil), do: {:timer_elapsed, token_id, marker}

  defp timer_wake(token_id, marker, boundary_node_id),
    do: {:boundary_timer_elapsed, token_id, boundary_node_id, marker}
end
