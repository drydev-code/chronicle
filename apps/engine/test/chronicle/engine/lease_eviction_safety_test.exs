defmodule Chronicle.Engine.LeaseEvictionSafetyTest do
  @moduledoc """
  Feature 3b safety hardening — the eviction + flush holes (S0-4 / S1-5).

  Under an ENABLED lease, an EVICTED `InstanceLoadCell` renews the ownership lease
  on its (non-resident) instance's behalf. This file proves the two safety
  properties an adversarial review found missing:

    * S0-4 / S1-5: when the evicted cell LOSES its lease on renew (a peer stole
      it), the cell must UNREGISTER its durable `:evicted_waits` rows and STOP —
      it must NOT keep itself alive for a later `:no_fence` restore that would
      resurrect an unfenced instance for a row a peer now owns.

    * S1-5: the eviction FLUSH (`Lifecycle.persist_events_sync`) is FENCED with
      the resident Instance's real `{owner_node, epoch}` fence, so a stale owner
      whose lease was already stolen cannot flush over a newer owner's log.

  N=1 / disabled stays a no-op: a `:no_fence` cell holds no lease, never renews,
  and never loses one — the existing single-pod path is untouched.

  Harness mirrors `lease_drain_test.exs`.
  """
  use ExUnit.Case, async: false

  alias Chronicle.Engine.{Instance, InstanceLoadCell}
  alias Chronicle.Engine.Diagrams.{DiagramStore, Parser}
  alias Chronicle.Persistence.{EventStore, InstanceLease}
  alias Chronicle.Persistence.Repo
  alias Chronicle.Persistence.Schemas.{ActiveInstance, CompletedInstance, TerminatedInstance}
  alias Chronicle.Engine.PersistentData

  @tenant "lease-evict"
  @ttl 30_000

  @message_bpjs %{
    "name" => "lease-evict-message",
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
      # Keep renew far out so it never fires on its own — tests poke :lease_renew
      # explicitly to drive the deterministic lost/kept outcome.
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
  # S0-4 / S1-5: a lost evicted lease unregisters + stops the cell (no no-fence
  # restore of an instance a peer now owns).
  # ===========================================================================

  describe "an evicted cell that loses its lease on renew is dropped (S0-4/S1-5)" do
    @tag :integration
    test "the cell unregisters its evicted waits + stops; it is NOT kept for a no-fence restore" do
      id = seed_unowned_active()
      bk = "bk-" <> id

      # A live peer owns the row; the evicted cell believes it holds an OLD epoch.
      assert {:ok, peer_epoch} = InstanceLease.acquire(id, "peer-pod", @ttl)

      handles = [
        %Chronicle.Engine.WaitingHandle.Message{
          instance_id: id,
          tenant_id: @tenant,
          message_name: "lease.message",
          business_key: bk,
          token_id: 1
        }
      ]

      {:ok, cell} =
        DynamicSupervisor.start_child(
          Chronicle.Engine.LoadCellSupervisor,
          %{
            id: {:cell, id},
            start: {InstanceLoadCell, :start_link, [{:evicted, id, @tenant, bk, handles}]},
            restart: :temporary
          }
        )

      # Give the cell a STALE real fence (a lower epoch than the peer just stole
      # to) so its next renew is :lost.
      stale = InstanceLease.fence("this-pod", peer_epoch - 1)
      :sys.replace_state(cell, fn s -> %{s | fence_epoch: stale} end)

      # The evicted wait is registered before the renew loss.
      assert evicted_message_registered?(id, bk)

      ref = Process.monitor(cell)
      send(cell, :lease_renew)

      # S0-4: the cell STOPS (dropped) rather than keeping itself for a no-fence
      # restore of a row a peer now owns.
      assert_receive {:DOWN, ^ref, :process, ^cell, _reason}, 2_000

      # S1-5: its durable :evicted_waits rows are gone, so wakes route to the new
      # owner — there is no stale cell left to resurrect a no-fence instance.
      refute evicted_message_registered?(id, bk)
      # The cell's :load_cells registration clears once the dead pid is reaped.
      assert await(fn -> InstanceLoadCell.lookup(@tenant, id) == {:error, :not_found} end)
    end
  end

  # ===========================================================================
  # S1-5: the eviction flush is fenced.
  # ===========================================================================

  describe "the eviction flush is fenced with the resident instance's real fence (S1-5)" do
    @tag :integration
    test "a resident instance whose lease was stolen cannot flush its eviction over the new owner's log" do
      id = seed_unowned_active()
      bk = "bk-" <> id
      node = Chronicle.Engine.NodeIdentity.node_id()

      # This pod acquires + restores the instance resident under a real fence.
      assert {:ok, epoch} = InstanceLease.acquire(id, node, @ttl)
      {:ok, events} = EventStore.stream(id)

      {:ok, inst} =
        DynamicSupervisor.start_child(
          Chronicle.Engine.InstanceSupervisor,
          {Instance, {:restore, id, @tenant, events, InstanceLease.fence(node, epoch)}}
        )

      assert await(fn -> match?({:ok, _}, Instance.lookup(@tenant, id)) end)
      assert await(fn -> match?(%{message_waits: w} when map_size(w) > 0, safe_state(inst)) end)

      # Build the cell over the resident instance, then simulate a peer STEALING
      # the lease (bump the epoch past us) so our held fence is now stale. The
      # eviction flush appends with our (stale) fence and MUST be fenced — the
      # eviction is aborted, the instance is NOT stopped/lost.
      {:ok, cell} =
        DynamicSupervisor.start_child(
          Chronicle.Engine.LoadCellSupervisor,
          %{
            id: {:cell, id},
            start: {InstanceLoadCell, :start_link, [{id, @tenant, bk, inst}]},
            restart: :temporary
          }
        )

      # A peer steals the (force-expired) lease, bumping the epoch past us so our
      # held {node, epoch} fence no longer matches the row.
      force_expire(id)
      assert {:ok, stolen} = InstanceLease.acquire(id, "peer-pod", @ttl)
      assert stolen > epoch

      # Drive an unpersisted event into the resident instance so the eviction
      # flush has a real delta to append (a fenced flush only matters when it
      # actually writes). We do this by appending to the in-memory state directly.
      :sys.replace_state(inst, fn s ->
        %{s | persistent_events: s.persistent_events ++ [token_in(id, "evict_flush")]}
      end)

      # Eviction: the flush appends with our stale fence -> fenced -> evict aborts.
      assert {:error, {:persist_failed, {:fenced, _}}} = InstanceLoadCell.evict(cell)

      # The peer's log is untouched by our fenced flush: no "evict_flush" event.
      refute "evict_flush" in for(e <- log(id),
                                  match?(%PersistentData.TokenFamilyCreated{}, e),
                                  do: e.current_node)

      if Process.alive?(cell), do: GenServer.stop(cell, :normal)
      if Process.alive?(inst), do: GenServer.stop(inst, :normal)
    end
  end

  # ===========================================================================
  # Seeding + helpers
  # ===========================================================================

  # Seed an active row by running a fresh instance to its message-wait park, then
  # clearing the lease ownership S0-3 stamped — so the test controls who owns it.
  defp seed_unowned_active do
    {:ok, definition} = Parser.parse(Jason.encode!(@message_bpjs))
    id = UUID.uuid4()
    bk = "bk-" <> id

    {:ok, pid} =
      Instance.start_link({definition, %{id: id, tenant_id: @tenant, business_key: bk}})

    assert await(fn -> match?(%{message_waits: w} when map_size(w) > 0, safe_state(pid)) end)
    assert EventStore.current_sequence(id) > 0
    GenServer.stop(pid, :normal)
    assert await(fn -> Instance.lookup(@tenant, id) == {:error, :not_found} end)

    Repo.get!(ActiveInstance, id)
    |> ActiveInstance.changeset(%{owner_node: nil, lease_expiry: nil, fence_epoch: 0})
    |> Repo.update!()

    id
  end

  defp token_in(_id, node_id),
    do: %PersistentData.TokenFamilyCreated{token: 1, family: 1, current_node: node_id}

  defp log(id) do
    {:ok, events} = EventStore.stream(id)
    events
  end

  defp evicted_message_registered?(_id, bk) do
    Registry.lookup(:evicted_waits, {@tenant, :message, "lease.message", bk}) != []
  end

  defp force_expire(id) do
    Repo.get!(ActiveInstance, id)
    |> ActiveInstance.changeset(%{lease_expiry: System.system_time(:millisecond) - 1})
    |> Repo.update!()
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
