defmodule Chronicle.Engine.RestoreLimiterVisibilityTest do
  @moduledoc """
  Regression tests for CODEX FINDING #6 (RestoreLimiter / evicted-wait
  visibility), see `docs/evicted-restart-plan.md`.

  Two gaps the evicted boot-restore path had before this fix:

    1. `RestoreLimiter` was UNBOUNDED unless `restore_max_concurrency` was set,
       so a `restore_mode: :evicted` boot storm could stampede
       `InstanceSupervisor`. The limiter now applies a sensible DEFAULT bound
       when `restore_mode: :evicted` is configured and no explicit cap is given;
       the `:resident` path stays `:infinity` (no-op).

    2. A cell UNREGISTERED all its `:evicted_waits` rows BEFORE acquiring the
       restore permit, then acquired the permit inside the async restore Task.
       Under a low concurrency cap a cell can sit QUEUED in `acquire/0` while its
       waits have already VANISHED — a concurrent trigger in that window finds no
       waiter and is dropped. The unregister now happens AFTER the permit is held
       (restore actually materialising), so queued restores keep their
       `:evicted_waits` visibility.
  """
  use ExUnit.Case, async: false

  alias Chronicle.Engine.{InstanceLoadCell, RestoreLimiter}

  @tenant "limiter-vis"

  setup do
    # Each test owns the limiter's global :counters ref, so run a fresh limiter
    # per test and tear it down (clearing the persistent_term) afterwards.
    on_exit(fn ->
      :persistent_term.erase({RestoreLimiter, :ref})
    end)

    :ok
  end

  describe "RestoreLimiter default bound" do
    test "is unbounded on the default :resident path (no explicit cap)" do
      with_env([], fn ->
        {:ok, pid} = start_limiter([])
        # Unbounded → acquire returns immediately and release is a no-op even
        # without any permits ever taken.
        assert RestoreLimiter.acquire() == :ok
        assert RestoreLimiter.acquire() == :ok
        assert :persistent_term.get({RestoreLimiter, :ref}) == :infinity
        stop(pid)
      end)
    end

    test "applies a default bound under restore_mode: :evicted when no explicit cap" do
      with_env([restore_mode: :evicted], fn ->
        {:ok, pid} = start_limiter([])
        # Bounded → a real counters ref is installed (not :infinity) with a
        # positive permit count.
        ref = :persistent_term.get({RestoreLimiter, :ref})
        refute ref == :infinity
        assert :counters.get(ref, 1) > 0
        stop(pid)
      end)
    end

    test "explicit restore_max_concurrency wins over the :evicted default" do
      with_env([restore_mode: :evicted, restore_max_concurrency: :infinity], fn ->
        {:ok, pid} = start_limiter([])
        # Operator explicitly opted OUT of bounding under :evicted.
        assert :persistent_term.get({RestoreLimiter, :ref}) == :infinity
        stop(pid)
      end)
    end
  end

  describe "evicted-wait visibility while a restore is queued behind the limiter" do
    test "a queued restore keeps its :evicted_waits row visible until a permit is acquired" do
      # Bound to a SINGLE permit. We drain it from the test process so the cell's
      # restore Task must QUEUE in acquire/0 — exactly the boot-storm window.
      {:ok, limiter} = start_limiter(max: 1)
      assert RestoreLimiter.acquire() == :ok

      msg_name = "boot.msg.#{System.unique_integer([:positive])}"
      iid = "vis-#{System.unique_integer([:positive])}"
      bk = "bk-#{iid}"

      handle = %Chronicle.Engine.WaitingHandle.Message{
        instance_id: iid,
        tenant_id: @tenant,
        message_name: msg_name,
        business_key: bk,
        token_id: 1
      }

      {:ok, cell} =
        InstanceLoadCell.start_link({:evicted, iid, @tenant, bk, [handle]})

      key = {@tenant, :message, msg_name, bk}

      # Evicted-from-inception → the wait is registered immediately.
      assert wait_registered?(key, cell)

      # Trigger a restore: the cell queues the wake, transitions to :restoring,
      # and spawns the restore Task which BLOCKS in acquire/0 (no permits left).
      GenServer.cast(cell, {:wake, :message, msg_name, %{}})

      # The cell is now :restoring but the permit is NOT yet held, so the
      # restore has NOT begun materialising. The wait MUST still be visible.
      # (Pre-fix: the unregister ran before acquire/0, so this row would already
      # be gone here — a concurrent trigger would find no waiter and drop.)
      assert eventually(fn -> InstanceLoadCell.inspect_cell(cell).cell_state == :restoring end)
      assert wait_registered?(key, cell),
             "evicted wait vanished while the restore was still QUEUED behind the limiter"

      # Release the permit: the restore Task proceeds, and only NOW does the
      # cell unregister its evicted wait (restore is materialising).
      RestoreLimiter.release()

      assert eventually(fn -> not wait_registered?(key, cell) end),
             "evicted wait was never unregistered after the restore acquired a permit"

      stop(cell)
      stop(limiter)
    end
  end

  describe "NEW-3: restore failure re-registers the evicted waits (waiter not lost)" do
    test "a transient :restore_failed leaves the :evicted_waits row present and the cell re-triggerable" do
      # Reproduce the crash window: `trigger_restore` UNREGISTERS the cell's
      # `:evicted_waits` rows (expecting the restored Instance to re-register its
      # own), then the materialisation fails transiently. Without the fix the rows
      # stay gone and a future trigger finds no waiter — the instance is lost.

      # Unbounded limiter so the restore Task's casts (unregister, then the
      # failure) actually run in order.
      {:ok, limiter} = start_limiter([])

      msg_name = "boot.msg.#{System.unique_integer([:positive])}"
      iid = "fail-#{System.unique_integer([:positive])}"
      bk = "bk-#{iid}"

      handle = %Chronicle.Engine.WaitingHandle.Message{
        instance_id: iid,
        tenant_id: @tenant,
        message_name: msg_name,
        business_key: bk,
        token_id: 1
      }

      {:ok, cell} =
        InstanceLoadCell.start_link({:evicted, iid, @tenant, bk, [handle]})

      key = {@tenant, :message, msg_name, bk}
      assert wait_registered?(key, cell)

      # Drive the exact cast sequence `trigger_restore`'s Task emits on a transient
      # failure: first drop the durable rows (permit held, restore materialising),
      # then report failure. Both are casts to the cell, processed in order.
      GenServer.cast(cell, {:unregister_evicted_waits, [handle]})
      assert eventually(fn -> not wait_registered?(key, cell) end)

      GenServer.cast(cell, :restore_failed)

      # NEW-3: after the failed restore the row must be back (exactly one), the
      # cell back in :evicted, and a subsequent wake must re-trigger a restore.
      assert eventually(fn -> wait_registered?(key, cell) end),
             "evicted wait was not re-registered after a transient :restore_failed — the waiter is lost"

      # Idempotent: exactly one row for this cell, not a duplicate.
      owned = Enum.count(Registry.lookup(:evicted_waits, key), fn {_o, v} -> v == cell end)
      assert owned == 1

      assert eventually(fn -> InstanceLoadCell.inspect_cell(cell).cell_state == :evicted end)

      # A subsequent wake is still routable: the cell finds its waiter and restores.
      GenServer.cast(cell, {:wake, :message, msg_name, %{}})
      assert eventually(fn -> InstanceLoadCell.inspect_cell(cell).cell_state in [:restore_requested, :restoring] end)

      stop(cell)
      stop(limiter)
    end
  end

  # --- helpers ---

  defp start_limiter(opts) do
    # Unnamed: acquire/0 and release/0 read the GLOBAL persistent_term ref the
    # limiter installs on init, so the registered name is irrelevant here and an
    # unnamed instance avoids colliding with any default-named limiter.
    RestoreLimiter.start_link(Keyword.put(opts, :name, nil))
  end

  defp stop(pid) when is_pid(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal)
  catch
    _, _ -> :ok
  end

  defp wait_registered?(key, cell) do
    Enum.any?(Registry.lookup(:evicted_waits, key), fn {_owner, value} -> value == cell end)
  end

  # Temporarily set :engine app env keys, restoring prior values afterwards.
  defp with_env(kvs, fun) do
    prev =
      Enum.map(kvs, fn {k, _v} ->
        {k, Application.fetch_env(:engine, k)}
      end)

    Enum.each(kvs, fn {k, v} -> Application.put_env(:engine, k, v) end)

    try do
      fun.()
    after
      Enum.each(prev, fn
        {k, {:ok, v}} -> Application.put_env(:engine, k, v)
        {k, :error} -> Application.delete_env(:engine, k)
      end)
    end
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end
end
