defmodule Chronicle.Persistence.TwoOwnerContentionTest do
  @moduledoc """
  Feature 3b, phase P5 — the headline TWO-OWNER CONTENTION safety proof.

  This is the core correctness argument for the whole ownership-lease feature.
  Two independent engine ownership *contexts* live in ONE BEAM, each with its own
  distinct node identity (`owner_a` / `owner_b`) but sharing ONE Repo / event log
  — exactly the situation during a rolling deploy where the old pod and the new
  pod both believe they should drive the same instance.

  Rather than stand up two full supervision trees (two sets of named Registries,
  LoadCells, etc.), this test drives the two primitives that actually enforce
  safety — `Chronicle.Persistence.InstanceLease` (MySQL CAS lease + fence epoch)
  and `Chronicle.Persistence.EventStore` (fenced append/complete) — directly with
  two node identities against the same shared Repo. A `%Owner{}` struct stands in
  for "an engine context that has acquired (or tried to acquire) the lease and is
  carrying a fence epoch it would thread through every write". That is precisely
  the state an `Instance` GenServer holds, so proving the primitives are safe here
  proves the layer is safe in the tree.

  We prove four things:

    1. Contention: both contexts attempt to acquire/restore the same instance ->
       EXACTLY ONE wins, the other is `:contended` and starts NO instance.
    2. Stale-epoch fence: the winner drives; the loser appends with its (never
       minted) / stale epoch -> `{:error, {:fenced, _}}`, and the durable event
       log is UNCHANGED by the loser (no divergent event).
    3. Expiry steal + fence-out: expire the winner's lease, the loser steals
       (epoch+1), the winner's next append is fenced -> the engine maps that to
       `:fenced_out` and stops -> the loser drives cleanly. The event log stays a
       SINGLE LINEAR sequence: no interleave, no double-applied token transition.
    4. Clean handoff: winner releases -> loser adopts -> replays the COMPLETE log
       and continues appending on top of it.

  N=1 invariant: with a single context there is never a second acquirer, so the
  loser branches below are simply unreachable — a single pod wins everything,
  renews forever, and fences with its own epoch. Nothing here changes the
  single-pod path; it only exercises the second pod that N=1 never has.
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Chronicle.Persistence.EventStore
  alias Chronicle.Persistence.InstanceLease
  alias Chronicle.Persistence.Repo
  alias Chronicle.Persistence.Schemas.{ActiveInstance, CompletedInstance, TerminatedInstance}
  alias Chronicle.Engine.PersistentData

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

  # ---------------------------------------------------------------------------
  # A stand-in for an engine ownership context: a distinct node identity plus
  # the fence epoch it currently believes it holds. `:no_epoch` means "this
  # context never won the lease" (so any write it attempts must be fenced or it
  # is mutating a log it does not own).
  # ---------------------------------------------------------------------------
  defmodule Owner do
    @moduledoc false
    defstruct [:node, epoch: :no_epoch]
  end

  defp owner(node), do: %Owner{node: node}

  # An engine context's "acquire-on-restore": try to win the lease for the
  # instance. On a win it records the minted epoch (this is exactly what the
  # supervisor's restore_active_instances does before starting the Instance);
  # on a loss it stays epoch-less and starts no instance.
  defp try_acquire(%Owner{node: node} = o, instance_id) do
    case InstanceLease.acquire(instance_id, node, @ttl) do
      {:ok, epoch} -> {:won, %Owner{o | epoch: epoch}}
      :contended -> {:contended, o}
      {:error, :not_found} -> {:not_found, o}
    end
  end

  # An engine context appending a token transition, fenced by the real
  # `{owner_node, epoch}` it holds. A context that never acquired (`:no_epoch`)
  # carries its own node but a clearly-stale epoch, so the fence rejects it (it
  # must never be able to write the shared log).
  defp append(%Owner{} = owner, instance_id, event) do
    EventStore.append_batch(instance_id, [event], fence_of(owner))
  end

  # The real `{owner_node, epoch}` fence token for an engine context. `:no_epoch`
  # (never acquired) maps to a stale epoch so any write it attempts is fenced.
  defp fence_of(%Owner{node: node, epoch: :no_epoch}), do: {node, -1}
  defp fence_of(%Owner{node: node, epoch: epoch}), do: {node, epoch}

  # ---- realistic, encodable token-transition events for a linear log ---------

  defp start_event(instance_id) do
    %PersistentData.ProcessInstanceStart{
      process_instance_id: instance_id,
      business_key: "bk",
      tenant: "00000000-0000-0000-0000-000000000000",
      process_name: "p",
      process_version: 1
    }
  end

  # A token entering a node, then leaving it — a real linear transition pair.
  defp token_in(node_id),
    do: %PersistentData.TokenFamilyCreated{token: 1, family: 1, current_node: node_id}

  defp token_out(node_id),
    do: %PersistentData.TokenFamilyRemoved{token: 1, family: 1, current_node: node_id}

  # Seed an unowned active row carrying only the start event (epoch 0, no owner)
  # — the durable starting point both contexts will race to own.
  defp seed_unowned(instance_id) do
    data = Jason.encode!([PersistentData.encode(start_event(instance_id))])

    %ActiveInstance{}
    |> ActiveInstance.changeset(%{process_instance_id: instance_id, data: data})
    |> Repo.insert!()
  end

  # Decode the durable log back into struct events so we can assert on its
  # contents — the single source of truth either context would replay from.
  defp durable_log(instance_id) do
    {:ok, events} = EventStore.stream(instance_id)
    events
  end

  # Expire the winner's lease in the past so a steal becomes possible WITHOUT
  # sleeping (mirrors how instance_lease_test simulates expiry).
  defp expire_lease(instance_id) do
    {1, _} =
      Repo.update_all(
        from(a in ActiveInstance, where: a.process_instance_id == ^instance_id),
        set: [lease_expiry: System.system_time(:millisecond) - 1]
      )

    :ok
  end

  describe "two engine ownership contexts contend for one instance" do
    @tag :integration
    test "the full safety lifecycle: exactly-one-wins, stale fenced, steal+fence-out, clean handoff" do
      id = Ecto.UUID.generate()
      seed_unowned(id)

      a = owner("owner_a")
      b = owner("owner_b")

      # --- (1) CONTENTION: both attempt acquire/restore -> exactly one wins ---
      {res_a, a} = try_acquire(a, id)
      {res_b, b} = try_acquire(b, id)

      outcomes = Enum.sort([res_a, res_b])
      assert outcomes == [:contended, :won], "exactly one context must win the lease"

      # Identify winner/loser by who carries an epoch. The loser started NO
      # instance: it holds no epoch and may not write.
      {winner, loser} =
        if res_a == :won, do: {a, b}, else: {b, a}

      assert winner.epoch == 1, "winner mints the first fence epoch on a fresh row"
      assert loser.epoch == :no_epoch, "the contended context never acquired an epoch"
      assert InstanceLease.owned_by_live_node?(id)
      assert InstanceLease.owned_by_other_live_node?(id, loser.node)
      refute InstanceLease.owned_by_other_live_node?(id, winner.node)

      # The durable log so far is just the start event.
      assert [%PersistentData.ProcessInstanceStart{}] = durable_log(id)
      assert EventStore.current_sequence(id) == 1

      # --- winner drives: a clean token-in / token-out transition ------------
      assert {:ok, _} = append(winner, id, token_in("task_1"))
      assert {:ok, _} = append(winner, id, token_out("task_1"))
      assert EventStore.current_sequence(id) == 3

      log_before_loser = durable_log(id)

      # --- (2) STALE-EPOCH FENCE: the loser tries to append -> fenced, and the
      #         durable log is UNCHANGED (no divergent event) ------------------
      assert {:error, {:fenced, current}} = append(loser, id, token_in("rogue_node"))
      assert current == winner.epoch, "fence reports the winner's live epoch"

      assert durable_log(id) == log_before_loser,
             "a fenced-out loser must not append a divergent event to the shared log"

      assert EventStore.current_sequence(id) == 3

      # --- (3) EXPIRY STEAL + FENCE-OUT --------------------------------------
      # The winner's lease expires (GC pause / slow pod). The loser steals it;
      # the fence epoch is bumped strictly past the winner.
      expire_lease(id)
      refute InstanceLease.owned_by_live_node?(id)

      {steal_res, loser} = try_acquire(loser, id)
      assert steal_res == :won, "loser steals the expired lease"
      assert loser.epoch == winner.epoch + 1, "a steal bumps the fence epoch past the old owner"

      # The OLD winner, unaware it was stolen, attempts its next append with its
      # now-stale epoch. The fence rejects it. The engine maps {:error, {:fenced,_}}
      # to a {:stop, :fenced_out, state} — assert exactly that classification.
      assert {:error, {:fenced, fenced_at}} = append(winner, id, token_in("stale_task"))
      assert fenced_at == loser.epoch
      assert classify_append(append(winner, id, token_in("stale_task_2"))) == :fenced_out

      # The new owner (loser) drives cleanly on top of the SAME log.
      log_at_steal = durable_log(id)
      assert {:ok, _} = append(loser, id, token_in("task_2"))
      assert {:ok, _} = append(loser, id, token_out("task_2"))

      # --- SINGLE LINEAR LOG: no interleave, no double-applied transition -----
      log = durable_log(id)

      # The old owner's two fenced attempts wrote NOTHING: the log grew by exactly
      # the loser's two appends past the steal point.
      assert length(log) == length(log_at_steal) + 2

      # The whole sequence is one clean, ordered, non-duplicated transition log.
      transitions =
        for e <- log do
          case e do
            %PersistentData.ProcessInstanceStart{} -> {:start, nil}
            %PersistentData.TokenFamilyCreated{current_node: n} -> {:in, n}
            %PersistentData.TokenFamilyRemoved{current_node: n} -> {:out, n}
          end
        end

      assert transitions == [
               {:start, nil},
               {:in, "task_1"},
               {:out, "task_1"},
               {:in, "task_2"},
               {:out, "task_2"}
             ],
             "the durable log is a single linear sequence with no rogue/stale/duplicate entries"

      # No rogue node ever made it in (loser's pre-steal attempt, winner's two
      # post-steal stale attempts).
      nodes = for {_, n} <- transitions, do: n
      refute "rogue_node" in nodes
      refute "stale_task" in nodes
      refute "stale_task_2" in nodes

      # --- (4) CLEAN HANDOFF: current owner releases -> a fresh context adopts,
      #         replays the COMPLETE log, and continues ----------------------
      assert :ok = InstanceLease.release(id, loser.node, loser.epoch)
      refute InstanceLease.owned_by_live_node?(id)

      adopter = owner("owner_c")
      {adopt_res, adopter} = try_acquire(adopter, id)
      assert adopt_res == :won, "after release the row is immediately adoptable"
      assert adopter.epoch == loser.epoch + 1, "adoption bumps the fence past the releaser"

      # The adopter replays the COMPLETE durable log it inherited — identical to
      # what the previous owner had written, nothing lost in handoff.
      replayed = durable_log(id)
      assert replayed == log, "adopter replays the full, unchanged log"
      assert length(replayed) == 5

      # ...and continues appending on top of it under its own fresh epoch.
      assert {:ok, _} = append(adopter, id, token_in("task_3"))
      assert EventStore.current_sequence(id) == 6

      # Final fence sanity: the long-dead original winner still cannot write.
      assert {:error, {:fenced, _}} = append(winner, id, token_in("zombie"))
      refute "zombie" in for(e <- durable_log(id),
                             match?(%PersistentData.TokenFamilyCreated{}, e),
                             do: e.current_node)
    end

    @tag :integration
    test "the contended loser starts no instance and cannot complete/terminate the shared log" do
      id = Ecto.UUID.generate()
      seed_unowned(id)

      winner = elem(try_acquire(owner("owner_a"), id), 1)
      {:contended, loser} = try_acquire(owner("owner_b"), id)
      assert loser.epoch == :no_epoch

      # A loser that never acquired must not be able to complete or terminate the
      # instance out from under the real owner. complete/terminate are fenced the
      # same way as append.
      assert {:error, {:fenced, _}} =
               EventStore.complete(id, [start_event(id)], fence_of(loser))

      assert {:error, {:fenced, _}} =
               EventStore.terminate(id, [start_event(id)], :killed, fence_of(loser))

      # The active row survives; nothing was moved to the terminal tables.
      assert Repo.get(ActiveInstance, id) != nil
      assert Repo.get(CompletedInstance, id) == nil
      assert Repo.get(TerminatedInstance, id) == nil

      # The real owner CAN complete cleanly at its live {owner, epoch}.
      assert {:ok, _} = EventStore.complete(id, durable_log(id), fence_of(winner))
      assert Repo.get(ActiveInstance, id) == nil
      assert Repo.get(CompletedInstance, id) != nil
    end
  end

  describe "fence verifies {owner_node, epoch}, not epoch alone (S2-7)" do
    @tag :integration
    test "a peer holding the SAME epoch number but a different node is still fenced" do
      id = Ecto.UUID.generate()
      seed_unowned(id)

      {:won, winner} = try_acquire(owner("owner_a"), id)
      assert winner.epoch == 1

      # owner_b never won the lease but forges a fence carrying owner_a's exact
      # live epoch (1). The fence must reject it because the node does not match —
      # epoch coincidence alone never grants the right to write.
      forged = %Owner{node: "owner_b", epoch: winner.epoch}
      assert {:error, {:fenced, current}} = append(forged, id, token_in("forged"))
      assert current == winner.epoch

      # Nothing the forger tried reached the log.
      refute "forged" in for(e <- durable_log(id),
                             match?(%PersistentData.TokenFamilyCreated{}, e),
                             do: e.current_node)

      # The genuine owner still drives.
      assert {:ok, _} = append(winner, id, token_in("real"))
    end
  end

  describe "S0-1: a stale owner cannot resurrect a peer-completed row" do
    @tag :integration
    test "after a peer steals + completes + deletes the row, the old owner's append is fenced :not_found" do
      id = Ecto.UUID.generate()
      seed_unowned(id)

      {:won, winner} = try_acquire(owner("owner_a"), id)
      assert {:ok, _} = append(winner, id, token_in("task_1"))

      # A peer steals the expired lease and COMPLETES the instance, which deletes
      # the active row entirely (it now lives in CompletedProcessInstances).
      expire_lease(id)
      {:won, thief} = try_acquire(owner("owner_b"), id)
      assert {:ok, _} = EventStore.complete(id, durable_log(id), fence_of(thief))
      assert Repo.get(ActiveInstance, id) == nil

      # The original winner, still believing it owns the instance, tries to append
      # with its (now-stale, and over a MISSING row) fence. Before the S0-1 fix a
      # nil row passed the fence and let the stale owner RECREATE the active row,
      # resurrecting a completed instance. It must now be fenced :not_found, and
      # the row must stay deleted.
      assert {:error, {:fenced, :not_found}} = append(winner, id, token_in("zombie"))
      assert Repo.get(ActiveInstance, id) == nil
      assert classify_append(append(winner, id, token_in("zombie_2"))) == :fenced_out
    end
  end

  # Mirror the engine's classification of an append result: a fenced write maps
  # to the :fenced_out stop reason that Instance uses to give up driving.
  defp classify_append({:error, {:fenced, _current}}), do: :fenced_out
  defp classify_append({:ok, _}), do: :ok
end
