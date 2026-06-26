defmodule Chronicle.Persistence.InstanceLeaseTest do
  use ExUnit.Case, async: false

  alias Chronicle.Persistence.InstanceLease
  alias Chronicle.Persistence.Repo
  alias Chronicle.Persistence.Schemas.ActiveInstance

  @ttl 30_000

  setup do
    repo = Application.get_env(:engine, :active_repo)

    if repo do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(repo)
      Ecto.Adapters.SQL.Sandbox.mode(repo, {:shared, self()})

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

  # Seed an unowned active row (fence_epoch defaults to 0). Optionally force a
  # lease state so we can simulate an already-held / already-expired lease
  # without sleeping.
  defp seed_instance(attrs \\ %{}) do
    id = Ecto.UUID.generate()

    %ActiveInstance{}
    |> ActiveInstance.changeset(Map.merge(%{process_instance_id: id, data: "[]"}, attrs))
    |> Repo.insert!()

    id
  end

  describe "acquire/3" do
    @tag :integration
    test "first acquirer wins on an unowned row and bumps the epoch to 1" do
      id = seed_instance()

      assert {:ok, epoch} = InstanceLease.acquire(id, "pod-a", @ttl)
      assert epoch == 1
      assert InstanceLease.owned_by_live_node?(id)
    end

    @tag :integration
    test "a second acquirer is :contended while the first lease is live" do
      id = seed_instance()

      assert {:ok, _e1} = InstanceLease.acquire(id, "pod-a", @ttl)
      assert :contended = InstanceLease.acquire(id, "pod-b", @ttl)
    end

    @tag :integration
    test "acquire on a missing row is {:error, :not_found}" do
      assert {:error, :not_found} =
               InstanceLease.acquire(Ecto.UUID.generate(), "pod-a", @ttl)
    end

    @tag :integration
    test "an expired lease is stolen and the epoch is bumped past the previous owner" do
      # Owner pod-a held epoch 1 but its lease already expired in the past.
      id =
        seed_instance(%{
          owner_node: "pod-a",
          lease_expiry: System.system_time(:millisecond) - 1,
          fence_epoch: 1
        })

      refute InstanceLease.owned_by_live_node?(id)

      assert {:ok, new_epoch} = InstanceLease.acquire(id, "pod-b", @ttl)
      assert new_epoch == 2, "steal must bump the fence epoch past the stale owner"
      assert InstanceLease.owned_by_live_node?(id)
    end
  end

  describe "renew/4" do
    @tag :integration
    test "the owner renews at its current epoch and keeps the lease live" do
      id = seed_instance()
      assert {:ok, epoch} = InstanceLease.acquire(id, "pod-a", @ttl)

      assert {:ok, ^epoch} = InstanceLease.renew(id, "pod-a", @ttl, epoch)
      assert InstanceLease.owned_by_live_node?(id)
    end

    @tag :integration
    test "renew after the lease was stolen returns :lost" do
      # pod-a acquires, then pod-b steals an expired lease (bumping the epoch);
      # pod-a's renew at its stale epoch must fail.
      id =
        seed_instance(%{
          owner_node: "pod-a",
          lease_expiry: System.system_time(:millisecond) - 1,
          fence_epoch: 1
        })

      assert {:ok, stolen_epoch} = InstanceLease.acquire(id, "pod-b", @ttl)
      assert stolen_epoch == 2

      assert :lost = InstanceLease.renew(id, "pod-a", @ttl, 1)
    end
  end

  describe "release/3" do
    @tag :integration
    test "the owner releases and the row becomes immediately acquirable again" do
      id = seed_instance()
      assert {:ok, epoch} = InstanceLease.acquire(id, "pod-a", @ttl)

      assert :ok = InstanceLease.release(id, "pod-a", epoch)
      refute InstanceLease.owned_by_live_node?(id)

      # Another pod can adopt right away without waiting for TTL expiry; the
      # epoch keeps climbing past the released owner's epoch.
      assert {:ok, next_epoch} = InstanceLease.acquire(id, "pod-b", @ttl)
      assert next_epoch == epoch + 1
    end

    @tag :integration
    test "release at a stale epoch (lease already stolen) returns :lost" do
      id =
        seed_instance(%{
          owner_node: "pod-a",
          lease_expiry: System.system_time(:millisecond) - 1,
          fence_epoch: 1
        })

      assert {:ok, 2} = InstanceLease.acquire(id, "pod-b", @ttl)

      assert :lost = InstanceLease.release(id, "pod-a", 1)
    end

    @tag :integration
    test "release on a missing row is idempotent :ok" do
      assert :ok = InstanceLease.release(Ecto.UUID.generate(), "pod-a", 1)
    end
  end
end
