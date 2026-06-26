defmodule Chronicle.Engine.LeaseConfig do
  @moduledoc """
  Single source of truth for the ownership-lease layer's runtime knobs
  (feature 3b, phase 2).

  Every lease-aware site — `Chronicle.Supervisor` (acquire-on-restore),
  `Chronicle.Engine.Instance` (per-instance renew), `Chronicle.Engine.LeaseManager`
  (boot scan + orphan/expired adoption) and `Chronicle.Engine.InstanceLoadCell`
  (renew the evicted instance's lease) — reads its config HERE so they can never
  disagree on whether the lease is on, the TTL, or the renew cadence.

  **N=1 / disabled invariant.** When `enabled?/0` is false (the default and the
  test config), the lease layer is a pure no-op: no lease is acquired on
  restore, no renew timer is armed, and the LeaseManager scan stays dormant. The
  existing single-pod path is then byte-for-byte the current behaviour. With the
  lease enabled at one pod, that pod wins every acquire, renews against its own
  live lease forever, never contends, and always fences with the epoch it just
  minted — observably identical.
  """

  @default_ttl_ms 30_000
  @default_renew_interval_ms 10_000
  @default_scan_interval_ms 15_000

  @doc "Is the ownership-lease layer enabled? Defaults to false (single-pod / test)."
  @spec enabled?() :: boolean()
  def enabled? do
    Keyword.get(config(), :enabled, false)
  end

  @doc "Lease time-to-live in milliseconds (how long an acquire/renew is good for)."
  @spec ttl_ms() :: non_neg_integer()
  def ttl_ms do
    Keyword.get(config(), :ttl_ms, @default_ttl_ms)
  end

  @doc """
  How often an owner renews its lease, in milliseconds. Defaults to ttl/3 so two
  renews can be missed before the lease expires and a peer may steal it.
  """
  @spec renew_interval_ms() :: non_neg_integer()
  def renew_interval_ms do
    Keyword.get(config(), :renew_interval_ms, default_renew_interval())
  end

  @doc "How often the LeaseManager scans for orphan/expired rows to adopt."
  @spec scan_interval_ms() :: non_neg_integer()
  def scan_interval_ms do
    Keyword.get(config(), :scan_interval_ms, @default_scan_interval_ms)
  end

  defp default_renew_interval do
    case ttl_ms() do
      ttl when is_integer(ttl) and ttl > 0 -> max(div(ttl, 3), 1)
      _ -> @default_renew_interval_ms
    end
  end

  defp config, do: Application.get_env(:engine, :lease, [])
end
