defmodule Chronicle.Engine.CallReturnSweeper do
  @moduledoc """
  Low-frequency, durable safety net for call returns to EVICTED parents.

  A child call-return is a PUSH: when a child completes it persists its OWN
  completion first (`Instance.complete_instance/1`) and THEN notifies the parent —
  a direct `GenServer.cast` to a resident parent, or, for an EVICTED parent, a
  `{:wake, :child_completed, ...}` cast to the parent's `InstanceLoadCell`
  (`Instance.notify_parent_child_completed/5`). That notification is VOLATILE: a
  crash between the child persisting and the parent recording its `CallCompleted`
  loses the wake with no durable redrive — the parent deadlocks forever on a
  child that is already terminal (CODEX FINDING #5).

  This sweeper closes that gap, mirroring the `TimerSweeper`. At eviction /
  boot-restore each open parent call wait is ALSO registered durably in the
  `:evicted_waits` registry as
  `{tenant, :call, parent_id, child_id} -> {cell_pid, token_id}` (see
  `InstanceLoadCell.Lifecycle.register_evicted_waits/2`). The sweeper periodically
  scans those rows and, for any whose child is durably TERMINAL
  (`EventStore.terminal_status/1` is `:completed` or `:terminated`) while the
  parent cell is still EVICTED (so the return was never recorded), re-pokes the
  cell (`InstanceLoadCell.redrive_child_return/4`). The poke restores the parent
  and records the return.

  Idempotent: once the parent has recorded its `CallCompleted`, replay removes the
  child from `call_wait_list`, so a second poke resolves `{:error, :not_found}` in
  `WaitRegistry.handle_child_completed` and appends nothing. The sweeper also
  unregisters the durable row once the cell leaves `:evicted` (the parent restored
  and is recording / has recorded the return), so a converged return stops being
  swept.

  Dormant by design: when no evicted `:call` rows exist the scan is a single cheap
  `Registry.select` returning `[]`. Like the `TimerSweeper` it is independent of
  `EvictionManager.enabled` and harmless on the default `:resident` path (no
  evicted `:call` rows are ever registered there).

  Configuration (in :engine, :call_return_sweeper):
  - scan_interval_ms: how often to scan (default: 30_000 = 30s)
  """
  use GenServer
  require Logger

  alias Chronicle.Engine.InstanceLoadCell
  alias Chronicle.Persistence.EventStore

  @default_scan_interval_ms 30_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Trigger an immediate sweep (used by tests and diagnostics)."
  def sweep_now do
    GenServer.call(__MODULE__, :sweep_now)
  end

  @impl true
  def init(_opts) do
    config = get_config()
    schedule_scan(config.scan_interval_ms)
    {:ok, config}
  end

  @impl true
  def handle_call(:sweep_now, _from, state) do
    swept = do_sweep()
    {:reply, {:ok, swept}, state}
  end

  @impl true
  def handle_info(:scan, state) do
    do_sweep()
    schedule_scan(state.scan_interval_ms)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Internal ---

  # Returns the number of owed call returns re-driven. Stays dormant (no work past
  # the select) when no evicted `:call` rows exist.
  defp do_sweep do
    call_entries()
    |> Enum.reduce(0, fn {child_id, cell_pid}, count ->
      if owed_return?(cell_pid, child_id) do
        successful = EventStore.terminal_status(child_id) == :completed
        InstanceLoadCell.redrive_child_return(cell_pid, child_id, %{}, successful)
        count + 1
      else
        count
      end
    end)
    |> tap_log()
  end

  # An evicted parent's call return is OWED iff the cell is still alive AND still
  # evicted (the return has NOT been recorded — once it is, the cell restores and
  # the durable row is unregistered) AND the child is durably terminal.
  defp owed_return?(cell_pid, child_id) do
    Process.alive?(cell_pid) and
      InstanceLoadCell.evicted?(cell_pid) and
      EventStore.terminal_status(child_id) in [:completed, :terminated]
  end

  # Select `{_, :call, parent_id, child_id}` keys and their `{cell_pid, token_id}`
  # value out of the duplicate `:evicted_waits` registry. `$1` = child_id (key),
  # `$2` = cell_pid (first element of the value tuple). Other wait types carry a
  # bare cell_pid value (message/signal) or a 5-element key (timer), so they are
  # excluded by this `:call`-keyed, 2-tuple-valued match.
  defp call_entries do
    Registry.select(:evicted_waits, [
      {{{:_, :call, :_, :"$1"}, :_, {:"$2", :_}}, [], [{{:"$1", :"$2"}}]}
    ])
  rescue
    # Registry not started (e.g. minimal test boot) — nothing to sweep.
    ArgumentError -> []
  end

  defp tap_log(0), do: 0

  defp tap_log(n) do
    Logger.info("CallReturnSweeper: re-drove #{n} owed call return(s) to evicted parent(s)")
    n
  end

  defp schedule_scan(interval_ms) do
    Process.send_after(self(), :scan, interval_ms)
  end

  defp get_config do
    config = Application.get_env(:engine, :call_return_sweeper, [])

    %{
      scan_interval_ms: Keyword.get(config, :scan_interval_ms, @default_scan_interval_ms)
    }
  end
end
