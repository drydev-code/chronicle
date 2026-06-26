defmodule Chronicle.Engine.LeaseDrainTest do
  @moduledoc """
  Phase 4 (feature 3b) graceful-drain tests.

  `LeaseManager.drain/0` releases every ownership lease this pod holds so a
  freshly-started pod can adopt the released instances IMMEDIATELY (no TTL wait,
  no double-drive — the fence still guards in-flight writes, and a clean release
  bumps no epoch so the next acquirer's bump is strictly higher). It covers both
  locally-owned actor kinds:

    * a RESIDENT `Instance` (`Instance.drain/1` flushes then releases its lease);
    * an EVICTED `InstanceLoadCell` (`InstanceLoadCell.drain/1` releases the
      lease the cell was renewing on the evicted instance's behalf).

  After drain the row's `owner_node` is NULL, and a subsequent `acquire` by a
  DIFFERENT identity (a new pod) succeeds — the adoption a rolling deploy needs.

  N=1 / disabled stays a no-op: a `:no_fence` actor holds no lease, so its drain
  is a flush-only no-op and no row ownership changes — the existing suite path.

  Harness mirrors `lease_manager_test.exs`.
  """
  use ExUnit.Case, async: false

  alias Chronicle.Engine.{Instance, InstanceLoadCell, LeaseManager}
  alias Chronicle.Engine.Diagrams.{DiagramStore, Parser}
  alias Chronicle.Persistence.{EventStore, InstanceLease}
  alias Chronicle.Persistence.Repo
  alias Chronicle.Persistence.Schemas.{ActiveInstance, CompletedInstance, TerminatedInstance}

  @tenant "lease-drain"
  @ttl 30_000

  @message_bpjs %{
    "name" => "lease-drain-message",
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
      # Keep renew far out so it never races the drain in these tests.
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
  # Resident instance drain: flush + release the held lease.
  # ===========================================================================

  describe "drain releases a RESIDENT instance's lease (owner cleared; adoptable)" do
    @tag :integration
    test "owner_node is nil after drain, the instance STOPS, and a different identity can acquire" do
      id = seed_parked()

      node = Chronicle.Engine.NodeIdentity.node_id()
      assert {:ok, epoch} = InstanceLease.acquire(id, node, @ttl)
      assert InstanceLease.owned_by_live_node?(id)

      {:ok, events} = EventStore.stream(id)

      {:ok, pid} =
        DynamicSupervisor.start_child(
          Chronicle.Engine.InstanceSupervisor,
          {Instance, {:restore, id, @tenant, events, InstanceLease.fence(node, epoch)}}
        )

      assert await(fn -> match?({:ok, _}, Instance.lookup(@tenant, id)) end)

      # Drain every local lease holder.
      assert {:ok, released} = LeaseManager.drain()
      assert released >= 1

      # The lease is released: owner_node cleared, no live lease, epoch untouched.
      assert current_owner(id) == nil
      refute InstanceLease.owned_by_live_node?(id)
      assert current_epoch(id) == epoch

      # S1-6 (a): a real-lease instance STOPS driving after release, so it can
      # never append on top of the row a new owner is about to adopt.
      assert await(fn -> Instance.lookup(@tenant, id) == {:error, :not_found} end)
      refute Process.alive?(pid)

      # A new pod (distinct identity) adopts immediately — no TTL wait — and its
      # acquire bumps the epoch strictly past the released one (no double-drive).
      assert {:ok, new_epoch} = InstanceLease.acquire(id, "pod-new", @ttl)
      assert new_epoch == epoch + 1
      assert current_owner(id) == "pod-new"
    end

    @tag :integration
    test "drain is idempotent: a second drain after release does not error or re-touch" do
      id = seed_parked()
      node = Chronicle.Engine.NodeIdentity.node_id()
      assert {:ok, epoch} = InstanceLease.acquire(id, node, @ttl)
      {:ok, events} = EventStore.stream(id)

      {:ok, _pid} =
        DynamicSupervisor.start_child(
          Chronicle.Engine.InstanceSupervisor,
          {Instance, {:restore, id, @tenant, events, InstanceLease.fence(node, epoch)}}
        )

      assert await(fn -> match?({:ok, _}, Instance.lookup(@tenant, id)) end)

      assert {:ok, _} = LeaseManager.drain()
      assert current_owner(id) == nil
      # The real-lease instance stopped after release.
      assert await(fn -> Instance.lookup(@tenant, id) == {:error, :not_found} end)

      # Second drain: no local actor left, no crash, owner stays nil
      # (release is idempotent / nothing to drain).
      assert {:ok, _} = LeaseManager.drain()
      assert current_owner(id) == nil
    end
  end

  # ===========================================================================
  # Evicted load-cell drain: release the lease the cell was renewing.
  # ===========================================================================

  describe "drain releases an EVICTED load cell's lease" do
    @tag :integration
    test "owner_node is nil after drain and a different identity can then acquire" do
      id = seed_parked()

      node = Chronicle.Engine.NodeIdentity.node_id()
      assert {:ok, epoch} = InstanceLease.acquire(id, node, @ttl)
      assert InstanceLease.owned_by_live_node?(id)

      # Stand up an evicted-from-inception cell for this instance and give it the
      # held epoch (the eviction path captures this from the resident Instance).
      bk = "bk-" <> id

      {:ok, cell} =
        DynamicSupervisor.start_child(
          Chronicle.Engine.LoadCellSupervisor,
          %{
            id: {:cell, id},
            start:
              {InstanceLoadCell, :start_link, [{:evicted, id, @tenant, bk, []}]},
            restart: :temporary
          }
        )

      :sys.replace_state(cell, fn s -> %{s | fence_epoch: InstanceLease.fence(node, epoch)} end)
      assert await(fn -> match?({:ok, _}, InstanceLoadCell.lookup(@tenant, id)) end)

      assert {:ok, released} = LeaseManager.drain()
      assert released >= 1

      assert current_owner(id) == nil
      refute InstanceLease.owned_by_live_node?(id)

      # New pod adopts immediately.
      assert {:ok, new_epoch} = InstanceLease.acquire(id, "pod-new", @ttl)
      assert new_epoch == epoch + 1
      assert current_owner(id) == "pod-new"

      # S1-6: after releasing the lease the cell STOPS and UNREGISTERS its waits —
      # the instance is no longer ours, so no wake/timer may restore it unfenced.
      assert await(fn -> not Process.alive?(cell) end)
      assert InstanceLoadCell.lookup(@tenant, id) == {:error, :not_found}
    end
  end

  # ===========================================================================
  # N=1 / disabled no-op gate: a `:no_fence` actor holds no lease, so drain is a
  # flush-only no-op — no row ownership changes (the existing single-pod path).
  # ===========================================================================

  describe "drain is a no-op for a :no_fence (lease-disabled / N=1) instance" do
    @tag :integration
    test "a :no_fence resident instance survives drain and touches no lease row" do
      # Restore WITHOUT a lease (`:no_fence`), exactly the disabled path.
      id = seed_parked()
      {:ok, events} = EventStore.stream(id)

      # Row stays unowned: no acquire.
      refute InstanceLease.owned_by_live_node?(id)

      {:ok, pid} =
        DynamicSupervisor.start_child(
          Chronicle.Engine.InstanceSupervisor,
          {Instance, {:restore, id, @tenant, events, :no_fence}}
        )

      assert await(fn -> match?({:ok, _}, Instance.lookup(@tenant, id)) end)

      # Drain: flush-only, no release. The instance is unharmed and still
      # resident, and the row is still unowned (owner stays nil, epoch stays 0).
      assert {:ok, _} = LeaseManager.drain()
      assert match?({:ok, _}, Instance.lookup(@tenant, id))
      assert current_owner(id) == nil
      assert current_epoch(id) == 0

      drain_stop(pid)
    end
  end

  # ===========================================================================
  # Seeding + helpers
  # ===========================================================================

  defp seed_parked do
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

    # With the lease ENABLED in setup, a freshly-created instance now ACQUIRES
    # its own lease (S0-3), leaving the row OWNED after the instance stops. These
    # tests acquire the lease themselves from an UNOWNED starting row, so clear
    # ownership here to restore the pre-S0-3 clean-slate the tests assume.
    Repo.get!(ActiveInstance, id)
    |> ActiveInstance.changeset(%{owner_node: nil, lease_expiry: nil, fence_epoch: 0})
    |> Repo.update!()

    id
  end

  defp drain_stop(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal)
  catch
    _, _ -> :ok
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
      safe_truthy(fun) -> true
      System.monotonic_time(:millisecond) > deadline -> false
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
