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
    timer_refs: %{}
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

  def handle_cast({:restore_completed, new_pid}, state) do
    if StateMachine.restore_completable?(state.cell_state) do
      Process.monitor(new_pid)
      drain_mailbox(new_pid, state.mailbox)
      Lifecycle.cancel_evicted_timers(state)

      Logger.info("InstanceLoadCell #{state.instance_id}: Restore completed, draining #{:queue.len(state.mailbox)} queued messages")

      {:noreply, %{state |
        cell_state: :resident,
        instance_pid: new_pid,
        waiting_handles: [],
        mailbox: :queue.new(),
        timer_refs: %{}
      }}
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

  defp forward_to_instance(pid, {:external_task_complete, task_id, payload, result}) do
    Instance.complete_external_task(pid, task_id, payload, result)
  end

  defp forward_to_instance(pid, {:external_task_error, task_id, error, retry?, backoff_ms}) do
    Instance.error_external_task(pid, task_id, error, retry?, backoff_ms)
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
