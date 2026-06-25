defmodule Chronicle.Engine.TimerSweeper do
  @moduledoc """
  Low-frequency, durable safety net for evicted-instance timers.

  Evicted instances arm their timers with `Process.send_after` on the
  `InstanceLoadCell` (the fast path). That ref dies if the cell crashes or the
  node restarts — so each evicted timer is ALSO registered durably in the
  `:evicted_waits` registry as
  `{tenant, :timer, instance_id, token_id, timer_id} ->
  {cell_pid, trigger_at, timer_id, boundary_node_id}` (see
  `InstanceLoadCell.Lifecycle.register_evicted_waits/2`). The key carries
  `timer_id` so multiple timers on one token stay distinct durable rows, and the
  value carries `timer_id` + `boundary_node_id` so the poke can forward the exact
  JSON-safe marker and route a boundary timer to its boundary continuation.

  This sweeper periodically scans those registrations and, for any whose
  `trigger_at` has passed, pokes the owning cell to restore + fire the timer
  (`InstanceLoadCell.sweep_timer/4`). The poke is idempotent: if the fast-path
  `send_after` already fired (or the token otherwise moved on), the restored
  instance ignores it.

  Dormant by design: when no evicted timer entries exist the scan is a single
  cheap `Registry.select` returning `[]` and nothing else runs. The scan only
  inspects registry rows — it never touches the EventStore — so it is safe to
  run on the default `:resident` restore path too (there it simply finds no
  evicted timer rows). It is independent of `EvictionManager.enabled`.

  Configuration (in :engine, :timer_sweeper):
  - scan_interval_ms: how often to scan (default: 30_000 = 30s)
  - grace_ms: only sweep timers whose trigger_at is older than now - grace,
    giving the fast-path send_after room to fire first (default: 5_000 = 5s)
  """
  use GenServer
  require Logger

  alias Chronicle.Engine.InstanceLoadCell

  @default_scan_interval_ms 30_000
  @default_grace_ms 5_000

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
    swept = do_sweep(state.grace_ms)
    {:reply, {:ok, swept}, state}
  end

  @impl true
  def handle_info(:scan, state) do
    do_sweep(state.grace_ms)
    schedule_scan(state.scan_interval_ms)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Internal ---

  # Returns the number of timer entries poked. Stays dormant (no work past the
  # select) when no evicted timer rows exist.
  defp do_sweep(grace_ms) do
    cutoff = System.system_time(:millisecond) - grace_ms

    due_timer_entries()
    |> Enum.reduce(0, fn {token_id, cell_pid, trigger_at, timer_id, boundary_node_id}, count ->
      if is_integer(trigger_at) and trigger_at <= cutoff and Process.alive?(cell_pid) do
        InstanceLoadCell.sweep_timer(cell_pid, token_id, timer_id, boundary_node_id)
        count + 1
      else
        count
      end
    end)
    |> tap_log()
  end

  # Select only `{_, :timer, instance_id, token_id, timer_id}` keys and their
  # `{cell_pid, trigger_at, timer_id, boundary_node_id}` value out of the
  # duplicate `:evicted_waits` registry. Other wait types (message/signal) carry a
  # bare cell_pid value and a shorter key, so they are excluded by the match.
  # `$1` = token_id, `$3` = cell_pid, `$4` = trigger_at, `$5` = timer_id (the exact
  # JSON-safe marker the poke forwards, distinguishing multiple timers per token),
  # `$6` = boundary_node_id (nil for a plain timer; routes a boundary timer to its
  # boundary continuation).
  defp due_timer_entries do
    Registry.select(:evicted_waits, [
      {{{:_, :timer, :_, :"$1", :_}, :"$2", {:"$3", :"$4", :"$5", :"$6"}}, [],
       [{{:"$1", :"$3", :"$4", :"$5", :"$6"}}]}
    ])
  rescue
    # Registry not started (e.g. minimal test boot) — nothing to sweep.
    ArgumentError -> []
  end

  defp tap_log(0), do: 0

  defp tap_log(n) do
    Logger.info("TimerSweeper: poked #{n} evicted timer(s) past trigger_at")
    n
  end

  defp schedule_scan(interval_ms) do
    Process.send_after(self(), :scan, interval_ms)
  end

  defp get_config do
    config = Application.get_env(:engine, :timer_sweeper, [])

    %{
      scan_interval_ms: Keyword.get(config, :scan_interval_ms, @default_scan_interval_ms),
      grace_ms: Keyword.get(config, :grace_ms, @default_grace_ms)
    }
  end
end
