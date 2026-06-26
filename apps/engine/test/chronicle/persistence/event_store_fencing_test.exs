defmodule Chronicle.Persistence.EventStoreFencingTest do
  @moduledoc """
  Feature 3b, phase P1 — fencing at the write boundary.

  The append/complete/terminate write boundary verifies the caller's
  `{owner_node, epoch}` fence against the FOR UPDATE-locked ActiveProcessInstances
  row inside the existing transaction. If a newer owner has (re)acquired the lease
  it has changed `owner_node` and/or bumped `fence_epoch`, and the write is
  REJECTED with `{:error, {:fenced, current}}` BEFORE any row mutation. A real
  fence over a MISSING row is rejected `{:error, {:fenced, :not_found}}` (S0-1) —
  a stale owner cannot resurrect a row a peer already completed + deleted. The
  `:no_fence` token (lease-less / single-pod / tests) skips the check entirely, so
  behaviour is byte-for-byte identical to before this layer existed — that
  back-compat property is what keeps the existing engine tests green.
  """
  use ExUnit.Case, async: false

  alias Chronicle.Persistence.EventStore
  alias Chronicle.Persistence.Repo
  alias Chronicle.Persistence.Schemas.{ActiveInstance, CompletedInstance, TerminatedInstance}
  alias Chronicle.Engine.PersistentData

  # The node identity the seeded rows are owned by. A real fence is the pair
  # `{owner_node, epoch}`; only the matching node AND epoch is accepted.
  @owner "node-a"

  setup do
    repo = Application.get_env(:engine, :active_repo)

    if repo do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(repo)
      Ecto.Adapters.SQL.Sandbox.mode(repo, {:shared, self()})
      Repo.delete_all(ActiveInstance)
      Repo.delete_all(CompletedInstance)
      Repo.delete_all(TerminatedInstance)

      on_exit(fn ->
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

  # A minimal, encodable event so the persisted `data` column is a real event list.
  defp event(instance_id) do
    %PersistentData.ProcessInstanceStart{
      process_instance_id: instance_id,
      business_key: "bk",
      tenant: "00000000-0000-0000-0000-000000000000",
      process_name: "p",
      process_version: 1
    }
  end

  # Seed an ActiveInstance row that already carries a durable fence_epoch, as an
  # owning pod would have written when it acquired the lease.
  defp seed_active(instance_id, fence_epoch, events) do
    data =
      events
      |> Enum.map(&PersistentData.encode/1)
      |> Jason.encode!()

    %ActiveInstance{}
    |> ActiveInstance.changeset(%{
      process_instance_id: instance_id,
      data: data,
      owner_node: @owner,
      lease_expiry: System.system_time(:millisecond) + 30_000,
      fence_epoch: fence_epoch
    })
    |> Repo.insert!()
  end

  describe "append_batch/3 fencing" do
    @tag :integration
    test "a stale epoch is rejected with {:error, {:fenced, current}} and does NOT mutate the row" do
      id = UUID.uuid4()
      seed_active(id, 5, [event(id)])

      before = Repo.get(ActiveInstance, id).data

      # Caller still believes it owns epoch 4, but the durable row is at 5.
      assert {:error, {:fenced, 5}} = EventStore.append_batch(id, [event(id)], {@owner, 4})

      # No row mutation: data length and epoch unchanged.
      row = Repo.get(ActiveInstance, id)
      assert row.data == before
      assert row.fence_epoch == 5
      assert EventStore.current_sequence(id) == 1
    end

    @tag :integration
    test "the current {owner, epoch} is accepted and appends" do
      id = UUID.uuid4()
      seed_active(id, 7, [event(id)])

      assert {:ok, _} = EventStore.append_batch(id, [event(id)], {@owner, 7})

      assert EventStore.current_sequence(id) == 2
      # The fence epoch is untouched by an accepted append.
      assert Repo.get(ActiveInstance, id).fence_epoch == 7
    end

    @tag :integration
    test "the right epoch but the WRONG owner_node is fenced (S2-7)" do
      id = UUID.uuid4()
      seed_active(id, 7, [event(id)])

      before = Repo.get(ActiveInstance, id).data

      # A different pod that coincidentally holds the same epoch number is still
      # fenced: the fence verifies owner_node AND epoch, not the epoch alone.
      assert {:error, {:fenced, 7}} = EventStore.append_batch(id, [event(id)], {"node-b", 7})

      assert Repo.get(ActiveInstance, id).data == before
      assert EventStore.current_sequence(id) == 1
    end

    @tag :integration
    test ":no_fence skips the check and appends (back-compat with arity-2)" do
      id = UUID.uuid4()
      seed_active(id, 9, [event(id)])

      # Explicit :no_fence, and the arity-2 delegate, both ignore the durable epoch.
      assert {:ok, _} = EventStore.append_batch(id, [event(id)], :no_fence)
      assert {:ok, _} = EventStore.append_batch(id, [event(id)])

      assert EventStore.current_sequence(id) == 3
    end

    @tag :integration
    test "S0-1: a real fence over a MISSING row is fenced {:fenced, :not_found}, NOT created" do
      id = UUID.uuid4()

      # No active row exists (a peer stole + completed + deleted it). A stale owner
      # carrying a real fence must NOT be allowed to recreate/append — it is fenced.
      assert {:error, {:fenced, :not_found}} = EventStore.append_batch(id, [event(id)], {@owner, 3})
      assert Repo.get(ActiveInstance, id) == nil
      assert EventStore.current_sequence(id) == 0
    end

    @tag :integration
    test ":no_fence onto a missing row still creates it (legacy create-bootstrap path)" do
      id = UUID.uuid4()

      assert {:ok, _} = EventStore.append_batch(id, [event(id)], :no_fence)
      assert EventStore.current_sequence(id) == 1
    end
  end

  describe "complete/4 fencing" do
    @tag :integration
    test "a stale epoch is rejected and the active row survives (no completed row written)" do
      id = UUID.uuid4()
      seed_active(id, 5, [event(id)])

      assert {:error, {:fenced, 5}} = EventStore.complete(id, [event(id)], {@owner, 4})

      assert Repo.get(ActiveInstance, id) != nil
      assert Repo.get(CompletedInstance, id) == nil
    end

    @tag :integration
    test "the wrong owner_node is fenced on complete (S2-7)" do
      id = UUID.uuid4()
      seed_active(id, 5, [event(id)])

      assert {:error, {:fenced, 5}} = EventStore.complete(id, [event(id)], {"node-b", 5})

      assert Repo.get(ActiveInstance, id) != nil
      assert Repo.get(CompletedInstance, id) == nil
    end

    @tag :integration
    test "S0-1: a real fence over a MISSING active row is fenced on complete" do
      id = UUID.uuid4()

      assert {:error, {:fenced, :not_found}} = EventStore.complete(id, [event(id)], {@owner, 4})
      assert Repo.get(CompletedInstance, id) == nil
    end

    @tag :integration
    test "the current {owner, epoch} completes; :no_fence also completes (back-compat)" do
      id1 = UUID.uuid4()
      seed_active(id1, 7, [event(id1)])
      assert {:ok, _} = EventStore.complete(id1, [event(id1)], {@owner, 7})
      assert Repo.get(ActiveInstance, id1) == nil
      assert Repo.get(CompletedInstance, id1) != nil

      id2 = UUID.uuid4()
      seed_active(id2, 7, [event(id2)])
      assert {:ok, _} = EventStore.complete(id2, [event(id2)])
      assert Repo.get(ActiveInstance, id2) == nil
      assert Repo.get(CompletedInstance, id2) != nil
    end
  end

  describe "terminate/4 fencing" do
    @tag :integration
    test "a stale epoch is rejected and the active row survives (no terminated row written)" do
      id = UUID.uuid4()
      seed_active(id, 5, [event(id)])

      assert {:error, {:fenced, 5}} = EventStore.terminate(id, [event(id)], :killed, {@owner, 4})

      assert Repo.get(ActiveInstance, id) != nil
      assert Repo.get(TerminatedInstance, id) == nil
    end

    @tag :integration
    test "the wrong owner_node is fenced on terminate (S2-7)" do
      id = UUID.uuid4()
      seed_active(id, 5, [event(id)])

      assert {:error, {:fenced, 5}} = EventStore.terminate(id, [event(id)], :killed, {"node-b", 5})

      assert Repo.get(ActiveInstance, id) != nil
      assert Repo.get(TerminatedInstance, id) == nil
    end

    @tag :integration
    test "S0-1: a real fence over a MISSING active row is fenced on terminate" do
      id = UUID.uuid4()

      assert {:error, {:fenced, :not_found}} =
               EventStore.terminate(id, [event(id)], :killed, {@owner, 4})

      assert Repo.get(TerminatedInstance, id) == nil
    end

    @tag :integration
    test "the current {owner, epoch} terminates; :no_fence also terminates (back-compat)" do
      id1 = UUID.uuid4()
      seed_active(id1, 7, [event(id1)])
      assert {:ok, _} = EventStore.terminate(id1, [event(id1)], :killed, {@owner, 7})
      assert Repo.get(ActiveInstance, id1) == nil
      assert Repo.get(TerminatedInstance, id1) != nil

      id2 = UUID.uuid4()
      seed_active(id2, 7, [event(id2)])
      assert {:ok, _} = EventStore.terminate(id2, [event(id2)], :killed)
      assert Repo.get(ActiveInstance, id2) == nil
      assert Repo.get(TerminatedInstance, id2) != nil
    end
  end
end
