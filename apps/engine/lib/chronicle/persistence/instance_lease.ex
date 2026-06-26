defmodule Chronicle.Persistence.InstanceLease do
  @moduledoc """
  MySQL compare-and-swap lease + fence-epoch primitives for instance ownership
  (feature 3b, phase 0).

  Exactly one pod may own (and therefore drive/append) an instance at a time.
  Ownership is recorded on the `ActiveProcessInstances` row itself via three
  additive columns:

    * `owner_node`   — the `NodeIdentity.node_id/0` of the current owner, or NULL
    * `lease_expiry` — epoch-milliseconds wall-clock deadline (BIGINT)
    * `fence_epoch`  — monotonic counter bumped on every (re)acquire

  Every operation is a *single conditional `UPDATE`* whose WHERE clause is the
  CAS guard, evaluated server-side against MySQL `NOW(3)` so that clock skew
  between pods can only ever cost an unnecessary steal — never a double-drive.
  `update_all` reports the affected-row count, which is the CAS outcome: 1 means
  we won, 0 means we lost (someone else holds a live lease, or — for renew /
  release — our epoch is stale).

  `fence_epoch` is the safety guarantee, not the lease: it is bumped on every
  acquire and returned so callers can fence their writes. A stale owner whose
  lease was stolen will see a higher epoch and have its append rejected (wired
  up in phase 1).

  **N=1 invariant:** a single pod acquires every row (all rows start unowned),
  renews against its own live lease forever, never contends, and always fences
  with the epoch it just minted. There are no callers yet in phase 0.
  """

  import Ecto.Query
  alias Chronicle.Persistence.Repo
  alias Chronicle.Persistence.Schemas.ActiveInstance

  # ---------------------------------------------------------------------------
  # Fence token (feature 3b safety hardening). A *real* lease fence is the pair
  # `{owner_node, epoch}` — the identity of the pod that acquired AND the epoch
  # it minted on that acquire. The write boundary verifies BOTH against the
  # FOR UPDATE-locked row, so a stale owner whose node OR epoch no longer matches
  # is fenced even if a coincidental epoch collision occurs (S2-7).
  #
  # `:no_fence` is the sole legacy / lease-disabled / N=1 / create-bootstrap
  # token. `fence/2`, `real_fence?/1` and `no_fence?/1` are the SINGLE gate every
  # caller uses to decide whether a drive path is fenced or running unfenced —
  # nothing else should pattern-match the raw token shape.
  # ---------------------------------------------------------------------------
  @type fence :: :no_fence | {String.t(), non_neg_integer()}

  @doc "Build a real fence token from the acquired owner node + epoch."
  @spec fence(String.t(), non_neg_integer()) :: fence()
  def fence(owner_node, epoch) when is_binary(owner_node) and is_integer(epoch),
    do: {owner_node, epoch}

  @doc """
  True when `fence` is a REAL lease fence (a `{owner_node, epoch}` pair) and so
  every write under it must be fenced. The single helper that gates whether
  `:no_fence` is allowed: only `false` here (i.e. `:no_fence`) may drive unfenced
  — the lease-disabled / N=1 / create-bootstrap path.
  """
  @spec real_fence?(fence()) :: boolean()
  def real_fence?({owner_node, epoch}) when is_binary(owner_node) and is_integer(epoch), do: true
  def real_fence?(_), do: false

  @doc "True for the legacy/disabled `:no_fence` token (the unfenced drive path)."
  @spec no_fence?(fence()) :: boolean()
  def no_fence?(fence), do: not real_fence?(fence)

  @doc "The owner node carried by a real fence, or nil for `:no_fence`."
  @spec fence_node(fence()) :: String.t() | nil
  def fence_node({owner_node, _epoch}), do: owner_node
  def fence_node(_), do: nil

  @doc "The epoch carried by a real fence, or nil for `:no_fence`."
  @spec fence_epoch(fence()) :: non_neg_integer() | nil
  def fence_epoch({_owner_node, epoch}), do: epoch
  def fence_epoch(_), do: nil

  # MySQL `NOW(3)` as epoch-milliseconds. UNIX_TIMESTAMP(NOW(3)) is a DECIMAL
  # with millisecond precision; *1000 then truncate to an integer ms value so it
  # is directly comparable with the BIGINT `lease_expiry` we store.
  defmacrop now_ms do
    quote do: fragment("CAST(UNIX_TIMESTAMP(NOW(3)) * 1000 AS UNSIGNED)")
  end

  @doc """
  Acquire (or steal an expired) lease for `instance_id` on behalf of `node`.

  Wins when the row is currently unowned (`owner_node IS NULL`) or its lease has
  expired (`lease_expiry < NOW`). On a win the fence epoch is bumped and the new
  epoch returned.

  Returns `{:ok, new_epoch}` on success, `:contended` when another node holds a
  live lease, or `{:error, :not_found}` when no active row exists for the id.
  """
  @spec acquire(binary(), String.t(), non_neg_integer()) ::
          {:ok, non_neg_integer()} | :contended | {:error, :not_found}
  def acquire(instance_id, node, ttl_ms)
      when is_binary(node) and is_integer(ttl_ms) and ttl_ms >= 0 do
    # S2-7 (a): the epoch returned MUST be the one THIS acquire wrote, never a
    # value a concurrent peer may have bumped to in the gap between the UPDATE
    # and a separate SELECT. Run both inside ONE transaction and read the epoch
    # back UNDER THE SAME `owner_node == ^node` predicate, so we only ever return
    # an epoch on a row we still own. If a peer raced in and stole between the
    # UPDATE committing and the read, the read finds no self-owned row and we
    # report `:contended` rather than handing back someone else's epoch.
    query =
      from a in ActiveInstance,
        where: a.process_instance_id == ^instance_id,
        where: is_nil(a.owner_node) or a.lease_expiry < now_ms(),
        update: [
          set: [
            owner_node: ^node,
            lease_expiry: now_ms() + ^ttl_ms,
            fence_epoch: a.fence_epoch + 1
          ]
        ]

    result =
      Repo.transaction(fn ->
        case Repo.update_all(query, []) do
          {1, _} ->
            case Repo.one(
                   from a in ActiveInstance,
                     where: a.process_instance_id == ^instance_id and a.owner_node == ^node,
                     select: a.fence_epoch,
                     lock: "FOR UPDATE"
                 ) do
              epoch when is_integer(epoch) -> {:ok, epoch}
              # We won the CAS but a peer immediately re-stole: do not return a
              # foreign epoch — treat as contended.
              nil -> :contended
            end

          {0, _} ->
            if exists?(instance_id), do: :contended, else: {:error, :not_found}
        end
      end)

    case result do
      {:ok, outcome} -> outcome
      {:error, _} -> :contended
    end
  end

  @doc """
  Renew an already-held lease, extending `lease_expiry` by `ttl_ms`.

  Succeeds only while `node` is still the recorded owner AND `epoch` still
  matches the row's `fence_epoch` — i.e. nobody has stolen the lease since this
  caller last acquired/renewed it. The epoch is NOT bumped on renew (renewing is
  not a handoff), so the caller's fence stays valid.

  Returns `{:ok, epoch}` (the unchanged epoch) on success, or `:lost` when the
  lease was stolen / the row is gone.
  """
  @spec renew(binary(), String.t(), non_neg_integer(), non_neg_integer()) ::
          {:ok, non_neg_integer()} | :lost
  def renew(instance_id, node, ttl_ms, epoch)
      when is_binary(node) and is_integer(ttl_ms) and ttl_ms >= 0 and is_integer(epoch) do
    query =
      from a in ActiveInstance,
        where: a.process_instance_id == ^instance_id,
        where: a.owner_node == ^node and a.fence_epoch == ^epoch,
        update: [set: [lease_expiry: now_ms() + ^ttl_ms]]

    case Repo.update_all(query, []) do
      {1, _} -> {:ok, epoch}
      {0, _} -> :lost
    end
  end

  @doc """
  Release a held lease, clearing ownership so another node can adopt the row
  immediately (without waiting for TTL expiry). Used by graceful drain.

  Succeeds only while `node` still owns the row at `epoch`. The fence epoch is
  left untouched so the next acquirer's bump is strictly higher than any epoch
  this owner ever fenced with. Returns `:ok` on success (including the no-op
  case where the lease was already lost — release is idempotent from the
  caller's point of view) and `:lost` only when the row still exists but is
  owned by someone else at a different epoch.
  """
  @spec release(binary(), String.t(), non_neg_integer()) :: :ok | :lost
  def release(instance_id, node, epoch)
      when is_binary(node) and is_integer(epoch) do
    query =
      from a in ActiveInstance,
        where: a.process_instance_id == ^instance_id,
        where: a.owner_node == ^node and a.fence_epoch == ^epoch,
        update: [set: [owner_node: nil, lease_expiry: nil]]

    case Repo.update_all(query, []) do
      {1, _} -> :ok
      {0, _} -> if exists?(instance_id), do: :lost, else: :ok
    end
  end

  @doc """
  True when the row exists and currently carries a *live* lease (owned and not
  yet expired per `NOW(3)`). Used by routing/retain decisions to avoid orphan-
  dropping a message destined for a row another live pod owns.
  """
  @spec owned_by_live_node?(binary()) :: boolean()
  def owned_by_live_node?(instance_id) do
    query =
      from a in ActiveInstance,
        where: a.process_instance_id == ^instance_id,
        where: not is_nil(a.owner_node) and a.lease_expiry >= now_ms(),
        select: 1

    Repo.one(query) == 1
  end

  @doc """
  True when the row exists and currently carries a *live* lease owned by a node
  OTHER than `node` (the caller's own `NodeIdentity.node_id/0`). The self-
  excluding variant of `owned_by_live_node?/1`: routing must never return
  `:not_owner` for an instance THIS pod owns (that would re-queue a reply to
  ourselves forever), only for one a *peer* live pod owns.

  **N=1 invariant:** the single pod owns every live lease, so `owner_node` is
  always its own `node`, the `!=` guard always fails, and this is always `false`
  — a pure no-op. It can only become true once a second pod owns a live lease.
  """
  @spec owned_by_other_live_node?(binary(), String.t()) :: boolean()
  def owned_by_other_live_node?(instance_id, node) when is_binary(node) do
    query =
      from a in ActiveInstance,
        where: a.process_instance_id == ^instance_id,
        where:
          not is_nil(a.owner_node) and a.owner_node != ^node and
            a.lease_expiry >= now_ms(),
        select: 1

    Repo.one(query) == 1
  end

  defp exists?(instance_id) do
    Repo.one(
      from a in ActiveInstance,
        where: a.process_instance_id == ^instance_id,
        select: 1
    ) == 1
  end
end
