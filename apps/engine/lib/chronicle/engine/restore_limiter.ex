defmodule Chronicle.Engine.RestoreLimiter do
  @moduledoc """
  Bounds the number of concurrent on-demand instance restores.

  On an `:evicted` boot, a broadcast trigger can wake many `InstanceLoadCell`s
  at once; each that decides to restore spawns a Task that starts a real
  `Instance` under `InstanceSupervisor` (see `InstanceLoadCell.Lifecycle.trigger_restore/1`).
  Unbounded, that is a thundering herd against `InstanceSupervisor` at PSS
  bulk-migration scale.

  This gate is a `:counters`-backed semaphore with `max` permits. Restore Tasks
  call `acquire/0` before `start_child` and `release/0` after. The cell stays in
  `:restore_requested`/`:restoring` while waiting, so per-cell de-dup still holds.

  Default behaviour is intentionally a no-op on the `:resident` path: `max` is
  `:infinity`, `acquire/0`/`release/0` return immediately, and the limiter has
  zero effect on the existing green suite.

  Under `restore_mode: :evicted` an UNCAPPED limiter is unsafe — a broadcast
  wake on a bulk-migration boot can stampede `InstanceSupervisor` with millions
  of simultaneous restores. So when `restore_mode: :evicted` is configured and
  `restore_max_concurrency` is NOT set, the limiter falls back to a sensible
  default bound (`@default_evicted_max`) rather than `:infinity`. An explicit
  `config :engine, restore_max_concurrency: N` always wins (use `:infinity` to
  opt out), and the `:resident` path stays unbounded so the green suite is
  unaffected.
  """
  use GenServer
  require Logger

  @name __MODULE__
  @acquire_poll_ms 25
  # Default concurrent-restore cap applied ONLY under `restore_mode: :evicted`
  # when `restore_max_concurrency` is unset. Bounds the boot-storm fan-out into
  # InstanceSupervisor while staying high enough not to throttle normal traffic.
  @default_evicted_max 50

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, @name))
  end

  @doc """
  Block until a restore permit is available, then return `:ok`.

  Returns immediately when the limiter is unbounded (`:infinity`) or not running,
  so callers on the `:resident` path are never gated.
  """
  def acquire(name \\ @name) do
    case bounded?(name) do
      false ->
        :ok

      ref ->
        if try_take(ref) do
          :ok
        else
          Process.sleep(@acquire_poll_ms)
          acquire(name)
        end
    end
  end

  @doc "Release a previously acquired permit. No-op when unbounded or not running."
  def release(name \\ @name) do
    case bounded?(name) do
      false -> :ok
      ref -> give_back(ref)
    end
  end

  # --- GenServer ---

  @impl true
  def init(opts) do
    max = Keyword.get(opts, :max, configured_max())

    case max do
      n when is_integer(n) and n > 0 ->
        ref = :counters.new(1, [:atomics])
        :counters.put(ref, 1, n)
        :persistent_term.put({__MODULE__, :ref}, ref)
        Logger.info("RestoreLimiter started: max_concurrent_restores=#{n}")
        {:ok, %{ref: ref, max: n}}

      _ ->
        :persistent_term.put({__MODULE__, :ref}, :infinity)
        Logger.info("RestoreLimiter started (unbounded)")
        {:ok, %{ref: :infinity, max: :infinity}}
    end
  end

  @impl true
  def terminate(_reason, _state) do
    :persistent_term.erase({__MODULE__, :ref})
    :ok
  end

  # --- Private ---

  # Resolve the permit cap from config:
  #   * explicit `restore_max_concurrency` always wins (incl. `:infinity` to
  #     deliberately opt out of bounding under :evicted);
  #   * otherwise `restore_mode: :evicted` gets a sensible DEFAULT bound so a
  #     boot storm cannot stampede InstanceSupervisor;
  #   * the default `:resident` path stays `:infinity` (no-op), keeping the
  #     existing green suite unaffected.
  defp configured_max do
    case Application.get_env(:engine, :restore_max_concurrency, :unset) do
      :unset ->
        case Application.get_env(:engine, :restore_mode, :resident) do
          :evicted -> @default_evicted_max
          _ -> :infinity
        end

      explicit ->
        explicit
    end
  end

  # Returns the counters ref when bounded, or false otherwise (unbounded / down).
  defp bounded?(_name) do
    case :persistent_term.get({__MODULE__, :ref}, :infinity) do
      :infinity -> false
      ref -> ref
    end
  rescue
    ArgumentError -> false
  end

  # Atomically take a permit if any remain. Returns true on success.
  defp try_take(ref) do
    current = :counters.get(ref, 1)

    if current > 0 do
      :counters.sub(ref, 1, 1)
      # Re-check for the (rare) lost race: another taker may have driven it
      # negative between get and sub. If so, hand the permit back and retry.
      if :counters.get(ref, 1) < 0 do
        :counters.add(ref, 1, 1)
        false
      else
        true
      end
    else
      false
    end
  end

  defp give_back(ref) do
    :counters.add(ref, 1, 1)
    :ok
  end
end
