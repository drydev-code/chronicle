defmodule Chronicle.Persistence.EventStore do
  @moduledoc "Append-only event store for process instance persistence."
  alias Chronicle.Persistence.Repo
  alias Chronicle.Persistence.Schemas.{ActiveInstance, CompletedInstance, TerminatedInstance}
  import Ecto.Query

  def create(instance_id, initial_event), do: create(instance_id, initial_event, :no_owner)

  @doc """
  Insert the initial active row for a brand-new instance.

  S0-3 (atomic create-with-lease): the legacy `:no_owner` form inserts an
  UNOWNED row (`owner_node` NULL, `fence_epoch` 0) — the lease-disabled / N=1 /
  test path, byte-identical to before this layer existed. The owned form
  `{node, ttl_ms}` inserts the row ALREADY OWNED — `owner_node = node`,
  `lease_expiry = now + ttl_ms`, `fence_epoch = 1` — in the SAME insert, so there
  is no window in which a freshly-created instance's row is unowned and a peer
  `LeaseManager` could steal it before the creator acquires. On success of the
  owned form the caller drives FENCED with `{node, 1}` immediately.

  Returns `{:ok, %{row, fence_epoch}}` (owned) / `{:ok, row}` (unowned legacy) or
  `{:error, reason}`. `lease_expiry` uses MySQL `NOW(3)` so it is computed
  server-side, consistent with every other lease CAS.
  """
  def create(instance_id, initial_event, :no_owner) do
    data = Jason.encode!([Chronicle.Engine.PersistentData.encode(initial_event)])

    %ActiveInstance{}
    |> ActiveInstance.changeset(%{process_instance_id: instance_id, data: data})
    |> Repo.insert()
  end

  def create(instance_id, initial_event, {node, ttl_ms})
      when is_binary(node) and is_integer(ttl_ms) and ttl_ms >= 0 do
    data = Jason.encode!([Chronicle.Engine.PersistentData.encode(initial_event)])

    # Atomic create-with-lease: a single INSERT that both CREATES and OWNS the
    # row (owner_node = node, fence_epoch = 1). A brand-new id has no row, so
    # there is no unowned window a peer LeaseManager could steal in.
    #
    # `lease_expiry` is computed from MySQL `NOW(3)` server-side (NOW(3)*1000 + ttl),
    # the SAME clock `acquire/renew` use — NOT the app clock (`System.system_time`).
    # Under multi-pod clock skew an app-clock initial deadline could read EARLIER
    # than a peer's NOW(3) comparison and let the row be stolen early (an
    # availability blip, never a double-drive — the durable fence is the safety
    # guarantee). Deriving it from DB time means all lease timing uses ONE clock.
    #
    # The deadline is `db_now_ms() + ttl_ms` — `db_now_ms/0` reads MySQL `NOW(3)`,
    # the SAME server clock `acquire/renew` compare against — so it cannot be set
    # from the app clock. (The changeset `insert` validates `lease_expiry` as an
    # integer and so cannot itself carry a SQL fragment; reading the DB clock into
    # an integer first keeps the deadline DB-derived while preserving the existing
    # atomic single-INSERT row shape.)
    lease_expiry = db_now_ms() + ttl_ms

    %ActiveInstance{}
    |> ActiveInstance.changeset(%{
      process_instance_id: instance_id,
      data: data,
      owner_node: node,
      lease_expiry: lease_expiry,
      fence_epoch: 1
    })
    |> Repo.insert()
    |> case do
      {:ok, row} -> {:ok, %{row: row, fence_epoch: 1}}
      {:error, _} = err -> err
    end
  end

  # MySQL `NOW(3)` as epoch-milliseconds, mirroring `InstanceLease`'s `now_ms`
  # fragment. The single clock every lease CAS uses, so the create-time deadline
  # is consistent with every later acquire/renew/steal comparison. Read through
  # the `Repo` facade (which exposes `one/2`, not `query!/1`) via a sourceless
  # fragment SELECT.
  defp db_now_ms do
    now_ms =
      Repo.one(
        from(f in fragment("SELECT CAST(UNIX_TIMESTAMP(NOW(3)) * 1000 AS UNSIGNED) AS now_ms"),
          select: f.now_ms
        )
      )

    case now_ms do
      n when is_integer(n) -> n
      %Decimal{} = d -> Decimal.to_integer(d)
      n when is_binary(n) -> String.to_integer(n)
    end
  end

  def append(instance_id, event) do
    encoded = Chronicle.Engine.PersistentData.encode(event)
    case Repo.get(ActiveInstance, instance_id) do
      nil ->
        create(instance_id, event)
      active ->
        existing = Jason.decode!(active.data)
        updated = existing ++ [encoded]
        active
        |> ActiveInstance.changeset(%{data: Jason.encode!(updated)})
        |> Repo.update()
    end
  end

  def stream(instance_id) do
    case Repo.get(ActiveInstance, instance_id) do
      nil -> {:error, :not_found}
      active ->
        events = active.data
          |> Jason.decode!()
          |> Enum.map(&Chronicle.Engine.PersistentData.decode/1)
        {:ok, events}
    end
  end

  def complete(instance_id, events), do: complete(instance_id, events, :no_fence)

  def complete(instance_id, events, fence) do
    data = events
      |> Enum.map(&Chronicle.Engine.PersistentData.encode/1)
      |> Jason.encode!()

    Repo.transaction(fn ->
      with :ok <- check_fence(instance_id, fence) do
        Repo.delete_all(from a in ActiveInstance, where: a.process_instance_id == ^instance_id)
        %CompletedInstance{}
        |> CompletedInstance.changeset(%{process_instance_id: instance_id, data: data})
        |> Repo.insert!()
      end
    end)
  end

  def terminate(instance_id, events, reason), do: terminate(instance_id, events, reason, :no_fence)

  def terminate(instance_id, events, _reason, fence) do
    data = events
      |> Enum.map(&Chronicle.Engine.PersistentData.encode/1)
      |> Jason.encode!()

    Repo.transaction(fn ->
      with :ok <- check_fence(instance_id, fence) do
        Repo.delete_all(from a in ActiveInstance, where: a.process_instance_id == ^instance_id)
        %TerminatedInstance{}
        |> TerminatedInstance.changeset(%{process_instance_id: instance_id, data: data})
        |> Repo.insert!()
      end
    end)
  end

  def append_batch(instance_id, events), do: append_batch(instance_id, events, :no_fence)

  def append_batch(_instance_id, [], _fence), do: {:ok, :noop}
  def append_batch(instance_id, events, fence) when is_list(events) do
    # Wrap read-modify-write in a transaction with a row-level lock so
    # concurrent appends for the same instance cannot trample each other.
    # Without the lock, two appenders could both read the same `existing`
    # list, each append their delta, and the later writer would clobber
    # the earlier one.
    Repo.transaction(fn ->
      row =
        from(a in ActiveInstance,
          where: a.process_instance_id == ^instance_id,
          lock: "FOR UPDATE"
        )
        |> Repo.one()

      # Fencing (feature 3b): with the row now FOR UPDATE-locked, verify the
      # caller's `{owner_node, epoch}` against the durable row. A real fence is
      # rejected BEFORE writing when the row's owner_node/fence_epoch no longer
      # match the caller (a newer owner stole the lease) OR the row is MISSING
      # (S0-1: a peer already completed + deleted it). `:no_fence` (lease-less /
      # single-pod / tests) skips the check entirely → identical behaviour to
      # before this layer existed.
      :ok = guard_fence!(row, fence)

      new_encoded = Enum.map(events, &Chronicle.Engine.PersistentData.encode/1)

      case row do
        nil ->
          data = Jason.encode!(new_encoded)

          case %ActiveInstance{}
               |> ActiveInstance.changeset(%{process_instance_id: instance_id, data: data})
               |> Repo.insert() do
            {:ok, inserted} -> inserted
            {:error, changeset} -> Repo.rollback(changeset)
          end

        active ->
          existing = Jason.decode!(active.data)
          updated = existing ++ new_encoded

          case active
               |> ActiveInstance.changeset(%{data: Jason.encode!(updated)})
               |> Repo.update() do
            {:ok, updated_row} -> updated_row
            {:error, changeset} -> Repo.rollback(changeset)
          end
      end
    end)
  end

  @doc """
  Returns the count of events already persisted for an instance.
  Returns 0 if no active row exists for this instance.
  """
  def current_sequence(instance_id) do
    case Repo.get(ActiveInstance, instance_id) do
      nil -> 0
      active ->
        case Jason.decode(active.data) do
          {:ok, list} when is_list(list) -> length(list)
          _ -> 0
        end
    end
  end

  @doc """
  Durable terminal status of an instance, derived purely from which table holds
  its row. Used by the `CallReturnSweeper` to decide — WITHOUT restoring the
  child — whether an evicted parent's outstanding call return is owed:

    * `:completed`  — child finished normally (CompletedProcessInstances row).
    * `:terminated` — child was terminated (TerminatedProcessInstances row).
    * `:active`     — child is still running (ActiveProcessInstances row), so no
      return is owed yet.
    * `:unknown`    — no row in any table (already reaped, or never existed).

  The active-row check is first and cheapest; only when it is absent do we probe
  the terminal tables.
  """
  def terminal_status(instance_id) do
    cond do
      Repo.get(ActiveInstance, instance_id) != nil -> :active
      Repo.get(CompletedInstance, instance_id) != nil -> :completed
      Repo.get(TerminatedInstance, instance_id) != nil -> :terminated
      true -> :unknown
    end
  end

  # --- Fencing helpers (feature 3b) ---

  # Called from inside an append_batch transaction where `row` is already the
  # FOR UPDATE-locked ActiveInstance (or nil). The fence token is either
  # `:no_fence` (legacy / lease-disabled / N=1 / create-bootstrap) or a real
  # `{owner_node, epoch}` pair.
  #
  # S2-7 (b): a real fence verifies BOTH that the locked row is still owned by
  # the caller's node AND that its durable `fence_epoch` matches the epoch the
  # caller acquired. A stale owner whose node/epoch no longer matches the row is
  # fenced even if epochs coincidentally collide.
  #
  # S0-1: a real fence over a MISSING active row (`nil`) is fenced
  # `{:fenced, :not_found}`, NOT passed. A nil row under a real epoch means a
  # peer already stole + completed/terminated + deleted the row; letting the
  # stale owner "create" it would resurrect a completed instance. Only
  # `:no_fence` (legacy create / lease-disabled) may proceed on a missing row.
  defp guard_fence!(_row, :no_fence), do: :ok

  defp guard_fence!(nil, {_owner_node, _epoch}), do: Repo.rollback({:fenced, :not_found})

  defp guard_fence!(%ActiveInstance{owner_node: row_owner, fence_epoch: current}, {owner_node, epoch}) do
    current = current || 0

    if row_owner == owner_node and current == epoch do
      :ok
    else
      Repo.rollback({:fenced, current})
    end
  end

  # Used by complete/terminate: re-read the fence under a FOR UPDATE lock inside
  # the transaction, then apply the same guard. `:no_fence` skips the lock+check.
  defp check_fence(_instance_id, :no_fence), do: :ok

  defp check_fence(instance_id, {_owner_node, _epoch} = fence) do
    row =
      from(a in ActiveInstance,
        where: a.process_instance_id == ^instance_id,
        lock: "FOR UPDATE"
      )
      |> Repo.one()

    guard_fence!(row, fence)
  end

  def delete_active(instance_id) do
    Repo.delete_all(from a in ActiveInstance, where: a.process_instance_id == ^instance_id)
  end

  def list_active_ids do
    Repo.all(from a in ActiveInstance, select: a.process_instance_id)
  end
end
