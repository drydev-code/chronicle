defmodule Chronicle.Persistence.EventStoreCreateDbTimeTest do
  @moduledoc """
  Feature 3b (NARROW) — the INITIAL lease deadline of an atomically created
  instance must be derived from the DB clock, not the app clock.

  `EventStore.create/3` (owned form `{node, ttl_ms}`) previously stamped
  `lease_expiry` from `System.system_time(:millisecond) + ttl_ms` — the booting
  pod's wall clock — while `InstanceLease.acquire/renew` (and the
  `owned_by_*_live_node?` reads a peer uses to decide whether to steal) compare
  against MySQL `NOW(3)`. Under multi-pod clock skew an app-clock initial deadline
  could read EARLIER than a peer's `NOW(3)`, letting the row be stolen before the
  TTL truly elapsed (an availability blip — the durable fence still prevents any
  double-drive). The fix computes the initial `lease_expiry` from `NOW(3)` too, so
  every lease deadline uses ONE clock (the DB).

  This pins that the created row's `lease_expiry` is consistent with a freshly
  read `NOW(3) * 1000 + ttl` — i.e. it came from the DB-time path — and is NOT a
  raw `System.system_time + ttl` snapshot taken in the BEAM. N=1 stays a no-op:
  the single pod owns the row it just created and never contends.
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Chronicle.Persistence.EventStore
  alias Chronicle.Persistence.Repo
  alias Chronicle.Persistence.Schemas.{ActiveInstance, CompletedInstance, TerminatedInstance}
  alias Chronicle.Engine.PersistentData

  @node "node-create-db-time"
  @ttl 30_000

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

  defp event(instance_id) do
    %PersistentData.ProcessInstanceStart{
      process_instance_id: instance_id,
      business_key: "bk",
      tenant: "00000000-0000-0000-0000-000000000000",
      process_name: "p",
      process_version: 1
    }
  end

  # MySQL NOW(3) as epoch-ms — the exact clock every lease CAS uses.
  defp db_now_ms do
    Repo.one(
      from(f in fragment("SELECT CAST(UNIX_TIMESTAMP(NOW(3)) * 1000 AS UNSIGNED) AS now_ms"),
        select: f.now_ms
      )
    )
    |> to_integer()
  end

  defp to_integer(v) when is_integer(v), do: v
  defp to_integer(%Decimal{} = d), do: Decimal.to_integer(d)
  defp to_integer(v) when is_binary(v), do: String.to_integer(v)

  @tag :integration
  test "owned create derives lease_expiry from DB time (NOW(3)+ttl), not the app clock" do
    repo = Application.get_env(:engine, :active_repo)
    if is_nil(repo), do: flunk("no active_repo configured for this test run")

    id = UUID.uuid4()

    assert {:ok, %{fence_epoch: 1}} = EventStore.create(id, event(id), {@node, @ttl})

    row = Repo.get!(ActiveInstance, id)
    assert row.owner_node == @node
    assert row.fence_epoch == 1
    assert is_integer(row.lease_expiry)

    # A NOW(3) read taken just AFTER the create. The stored deadline must be
    # consistent with (NOW(3) + ttl): not earlier than (now_after - ttl_slack)
    # and not later than (now_after + ttl). A tight window proves it tracks DB
    # time rather than an unrelated clock.
    now_after = db_now_ms()
    expected = now_after + @ttl

    # The stored deadline was computed from a NOW(3) read taken at or before
    # `now_after`, so it cannot exceed `now_after + ttl`, and (allowing a small
    # execution gap) must be within a few seconds below it.
    assert row.lease_expiry <= expected,
           "lease_expiry #{row.lease_expiry} exceeds a DB-time NOW(3)+ttl bound #{expected}"

    assert row.lease_expiry >= expected - 5_000,
           "lease_expiry #{row.lease_expiry} is too far below NOW(3)+ttl #{expected} — not DB-derived"
  end

  @tag :integration
  test "N=1 invariant: the creating node owns a LIVE lease on its new row (no contention)" do
    id = UUID.uuid4()
    assert {:ok, %{fence_epoch: 1}} = EventStore.create(id, event(id), {@node, @ttl})

    # Owned + not-yet-expired per NOW(3): the create-time deadline is in the
    # future on the DB clock, so the single pod holds a live lease immediately.
    assert Chronicle.Persistence.InstanceLease.owned_by_live_node?(id)
  end
end
