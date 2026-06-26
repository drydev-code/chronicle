defmodule Chronicle.Engine.LeaseCreateRestoreSafetyTest do
  @moduledoc """
  Feature 3b safety hardening — the remaining lease holes (S0-3 / S1-6 / the
  boot-restore composition gap).

  Under an ENABLED lease this file proves the three properties an adversarial
  sweep found missing:

    * S0-3 (atomic create-with-lease): a freshly-CREATED instance's `Active` row
      is ALREADY OWNED at create time — `owner_node` = this node, `fence_epoch`
      = 1 — with NO unowned window between create and acquire. A peer acquire on
      that row is therefore `:contended`, never a steal that would let the
      creator fall back to `:no_fence` and split-brain.

    * S1-6 (evicted drain stops the cell): graceful drain of an EVICTED cell
      RELEASES the lease AND stops + unregisters the cell, so no wake/timer can
      restore the (no-longer-ours) instance unfenced after release.

    * Boot-restore composition: `EvictedWaitRestorer` under an enabled lease
      ACQUIRES a lease per instance, restores ONLY the ones it WINS (threading
      the won fence), and SKIPS a row a live peer owns (`:contended`).

  N=1 / disabled stays a no-op everywhere — covered by the existing suite.

  Harness mirrors `lease_drain_test.exs` / `lease_eviction_safety_test.exs`.
  """
  use ExUnit.Case, async: false

  alias Chronicle.Engine.{EvictedWaitRestorer, Instance, InstanceLoadCell, LeaseManager}
  alias Chronicle.Engine.Diagrams.{DiagramStore, Parser}
  alias Chronicle.Persistence.{EventStore, InstanceLease}
  alias Chronicle.Persistence.Repo
  alias Chronicle.Persistence.Schemas.{ActiveInstance, CompletedInstance, TerminatedInstance}

  @tenant "lease-create-restore"
  @ttl 30_000

  @message_bpjs %{
    "name" => "lease-create-restore-message",
    "version" => 1,
    "nodes" => [
      %{"id" => 1, "type" => "blankStartEvent"},
      %{
        "id" => 2,
        "type" => "intermediateCatchMessageEvent",
        "message" => %{"name" => "lease.message"}
      },
      %{"id" => 3, "type" => "blankEndEvent"}
    ],
    "connections" => [
      %{"from" => 1, "to" => 2},
      %{"from" => 2, "to" => 3}
    ]
  }

  setup_all do
    start_unlinked(Chronicle.Engine.Scripting.ScriptPool, [])
    start_unlinked(DiagramStore, [])

    start_unlinked_supervisor(
      {DynamicSupervisor, name: Chronicle.Engine.LoadCellSupervisor, strategy: :one_for_one}
    )

    start_unlinked_supervisor(
      {DynamicSupervisor, name: Chronicle.Engine.InstanceSupervisor, strategy: :one_for_one}
    )

    start_unlinked(Chronicle.Engine.RestoreLimiter, [])

    {:ok, definition} = Parser.parse(Jason.encode!(@message_bpjs))
    :ok = DiagramStore.register(definition.name, definition.version, @tenant, definition)

    :ok
  end

  setup do
    repo = Application.get_env(:engine, :active_repo)

    prior_lease = Application.get_env(:engine, :lease)

    Application.put_env(:engine, :lease,
      enabled: true,
      ttl_ms: @ttl,
      renew_interval_ms: 60_000,
      scan_interval_ms: 60_000
    )

    if repo do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(repo)
      Ecto.Adapters.SQL.Sandbox.mode(repo, {:shared, self()})
      Repo.delete_all(ActiveInstance)
      Repo.delete_all(CompletedInstance)
      Repo.delete_all(TerminatedInstance)

      on_exit(fn ->
        terminate_children(Chronicle.Engine.InstanceSupervisor)
        terminate_children(Chronicle.Engine.LoadCellSupervisor)

        if prior_lease do
          Application.put_env(:engine, :lease, prior_lease)
        else
          Application.delete_env(:engine, :lease)
        end

        try do
          Ecto.Adapters.SQL.Sandbox.mode(repo, :manual)
        rescue
          _ -> :ok
        end
      end)

      {:ok, repo: repo}
    else
      {:ok, repo: nil}
    end
  end

  # ===========================================================================
  # (1) S0-3: atomic create-with-lease — the new row is OWNED at create time.
  # ===========================================================================

  describe "S0-3: a freshly created instance OWNS its row at create time" do
    @tag :integration
    test "Active row carries owner_node + fence_epoch 1 immediately; a peer acquire is :contended" do
      {:ok, definition} = Parser.parse(Jason.encode!(@message_bpjs))
      id = UUID.uuid4()
      bk = "bk-" <> id
      node = Chronicle.Engine.NodeIdentity.node_id()

      {:ok, pid} =
        Instance.start_link({definition, %{id: id, tenant_id: @tenant, business_key: bk}})

      # The instance parks on its message wait; by then the start row must already
      # exist AND be owned (the create itself took ownership, no later acquire).
      assert await(fn -> match?(%{message_waits: w} when map_size(w) > 0, safe_state(pid)) end)

      row = Repo.get!(ActiveInstance, id)
      assert row.owner_node == node, "create did not own the new row (S0-3)"
      assert row.fence_epoch == 1, "atomic create must mint fence_epoch 1"
      assert is_integer(row.lease_expiry) and row.lease_expiry > 0

      # The row carries a LIVE lease for this node — there was never an unowned
      # window for a peer to steal in.
      assert InstanceLease.owned_by_live_node?(id)

      # A peer (distinct identity) acquiring the same row LOSES — it is contended,
      # proving the create-then-acquire gap is closed.
      assert InstanceLease.acquire(id, "pod-peer", @ttl) == :contended

      GenServer.stop(pid, :normal)
    end
  end

  # ===========================================================================
  # (2) S1-6: evicted drain STOPS + UNREGISTERS the cell (no wake can restore).
  # ===========================================================================

  describe "S1-6: draining an evicted cell stops it so no wake restores it unfenced" do
    @tag :integration
    test "after drain the cell is gone (Instance.lookup + cell lookup -> not found)" do
      {id, bk, msg_handle} = seed_evicted_handle()

      node = Chronicle.Engine.NodeIdentity.node_id()
      assert {:ok, epoch} = InstanceLease.acquire(id, node, @ttl)

      {:ok, cell} =
        DynamicSupervisor.start_child(
          Chronicle.Engine.LoadCellSupervisor,
          %{
            id: {:cell, id},
            start:
              {InstanceLoadCell, :start_link,
               [{:evicted, id, @tenant, bk, [msg_handle], InstanceLease.fence(node, epoch)}]},
            restart: :temporary
          }
        )

      assert await(fn -> match?({:ok, _}, InstanceLoadCell.lookup(@tenant, id)) end)
      # The cell registered its evicted wait (routable).
      assert wait_registered?(msg_handle)

      assert {:ok, _} = LeaseManager.drain()

      # Lease released for adoption.
      assert current_owner(id) == nil

      # S1-6: the cell STOPPED and UNREGISTERED — no Instance, no cell, no wait
      # row, so nothing can wake it back into a `:no_fence` restore.
      assert await(fn -> not Process.alive?(cell) end)
      assert InstanceLoadCell.lookup(@tenant, id) == {:error, :not_found}
      assert Instance.lookup(@tenant, id) == {:error, :not_found}
      refute wait_registered?(msg_handle)
    end
  end

  # ===========================================================================
  # (3) EvictedWaitRestorer under an enabled lease: restore only the won rows,
  #     thread the fence, skip a foreign-owned one.
  # ===========================================================================

  describe "EvictedWaitRestorer composes with the lease" do
    @tag :integration
    test "restores + fences a won instance; SKIPS a foreign-owned one" do
      # Two parked active instances, both unowned to start.
      {won_id, _bk_won, _h1} = seed_evicted_handle()
      {foreign_id, _bk_foreign, _h2} = seed_evicted_handle()

      # A live PEER owns the second instance's row before restore runs.
      assert {:ok, foreign_epoch} = InstanceLease.acquire(foreign_id, "pod-peer", @ttl)
      assert InstanceLease.owned_by_other_live_node?(foreign_id, Chronicle.Engine.NodeIdentity.node_id())

      # Restore the WON one: this pod acquires the (unowned) lease and starts an
      # evicted cell carrying the won fence.
      assert is_integer(EvictedWaitRestorer.restore_waits_for(won_id))

      node = Chronicle.Engine.NodeIdentity.node_id()
      assert current_owner(won_id) == node, "restorer did not acquire the won lease"
      assert {:ok, won_cell} = InstanceLoadCell.lookup(@tenant, won_id)

      # The cell holds a REAL fence (threaded in) and renews against it.
      assert match?({^node, _epoch}, :sys.get_state(won_cell).fence_epoch)

      # Restore the FOREIGN one: the peer owns a live lease, so the restorer
      # SKIPS it — no cell, no resident instance, ownership unchanged.
      assert EvictedWaitRestorer.restore_waits_for(foreign_id) == :contended
      assert current_owner(foreign_id) == "pod-peer"
      assert current_epoch(foreign_id) == foreign_epoch
      assert InstanceLoadCell.lookup(@tenant, foreign_id) == {:error, :not_found}
      assert Instance.lookup(@tenant, foreign_id) == {:error, :not_found}
    end
  end

  # ===========================================================================
  # Seeding + helpers
  # ===========================================================================

  # Create a parked instance, stop it, and clear ownership so the row is an
  # UNOWNED clean slate (these tests acquire / restore from unowned). Returns the
  # id, business key, and the open message WaitingHandle the evicted cell would
  # register.
  defp seed_evicted_handle do
    {:ok, definition} = Parser.parse(Jason.encode!(@message_bpjs))
    id = UUID.uuid4()
    bk = "bk-" <> id

    {:ok, pid} =
      Instance.start_link({definition, %{id: id, tenant_id: @tenant, business_key: bk}})

    assert await(fn -> match?(%{message_waits: w} when map_size(w) > 0, safe_state(pid)) end),
           "instance did not park on its message wait"

    assert EventStore.current_sequence(id) > 0

    GenServer.stop(pid, :normal)
    assert await(fn -> Instance.lookup(@tenant, id) == {:error, :not_found} end)

    # S0-3 means the create owned the row; clear it to the pre-S0-3 clean slate
    # these tests acquire/restore from.
    Repo.get!(ActiveInstance, id)
    |> ActiveInstance.changeset(%{owner_node: nil, lease_expiry: nil, fence_epoch: 0})
    |> Repo.update!()

    handle = %Chronicle.Engine.WaitingHandle.Message{
      instance_id: id,
      tenant_id: @tenant,
      message_name: "lease.message",
      business_key: bk,
      token_id: 0
    }

    {id, bk, handle}
  end

  defp wait_registered?(%Chronicle.Engine.WaitingHandle.Message{
         tenant_id: tenant,
         message_name: name,
         business_key: bk
       }) do
    Registry.lookup(:evicted_waits, {tenant, :message, name, bk}) != []
  end

  defp current_owner(id) do
    Repo.get(ActiveInstance, id) |> then(& &1.owner_node)
  end

  defp current_epoch(id) do
    Repo.get(ActiveInstance, id) |> then(& &1.fence_epoch)
  end

  defp safe_state(pid) do
    if Process.alive?(pid), do: :sys.get_state(pid), else: %{}
  end

  defp await(fun, timeout_ms \\ 3_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await(fun, deadline)
  end

  defp do_await(fun, deadline) do
    cond do
      safe_truthy(fun) ->
        true

      System.monotonic_time(:millisecond) > deadline ->
        false

      true ->
        Process.sleep(20)
        do_await(fun, deadline)
    end
  end

  defp safe_truthy(fun) do
    fun.()
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp terminate_children(supervisor) do
    case Process.whereis(supervisor) do
      nil ->
        :ok

      _pid ->
        for {_, child, _, _} <- DynamicSupervisor.which_children(supervisor), is_pid(child) do
          DynamicSupervisor.terminate_child(supervisor, child)
        end

        :ok
    end
  rescue
    _ -> :ok
  end

  defp start_unlinked(module, args) do
    case module.start_link(args) do
      {:ok, pid} -> Process.unlink(pid)
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  defp start_unlinked_supervisor({DynamicSupervisor, opts}) do
    case DynamicSupervisor.start_link(opts) do
      {:ok, pid} -> Process.unlink(pid)
      {:error, {:already_started, _pid}} -> :ok
    end
  end
end
