defmodule Chronicle.Engine.Instance.WaitIdLoopbackReplayTest do
  @moduledoc """
  Phase-3a regression for the durable wait-activation id (`wait_id`, B'.1).

  Scenarios (see docs/inbox-redesign-plan.md §B'.1 and docs/inbox-scenarios.md):

    * B5 — an instance loops back to the SAME message catch. Two DISTINCT
      `wait_id`s must be minted (one per activation), the `:waits` registry value
      must carry the per-occurrence `wait_id` (not just `token_id`), and the
      retention/replay identity is the `wait_id` — so the SAME physical
      `message_id` may be consumed once per `wait_id`. The weak "twice with two
      different messages" assertion does NOT catch a per-`token_id` block; this
      test asserts the per-occurrence `wait_id` identity directly.

    * E2 — engine restart / replay mid-wait. A persisted `MessageWaitCreated`
      carries its minted `wait_id`; on replay the SAME `wait_id` is re-registered
      in `:waits` (read-not-re-minted), so a redelivery neither double-fires nor
      blocks.

  Unique module + fixture names (tenant `widlr-*`, business_key `widlr-bk-*`,
  catch name `widlr-loop-msg`) so sibling Phase-4 test files running with
  `async: false` against the shared :waits Registry do not collide.
  """
  use ExUnit.Case, async: false

  alias Chronicle.Engine.{Token, TokenProcessor, PersistentData, Nodes}
  alias Chronicle.Engine.Diagrams.{Definition, DiagramStore}
  alias Chronicle.Engine.Instance.{EventReplayer, TokenState}

  @tenant "widlr-tenant"
  @business_key "widlr-bk-1"
  @catch_name "widlr-loop-msg"

  setup do
    # Shared :waits Registry (:duplicate) — reuse if the engine supervisor or a
    # sibling test already started it. Mirrors WaitRegistryTest's setup.
    case Registry.start_link(keys: :duplicate, name: :waits) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    case Chronicle.Engine.Scripting.ScriptPool.start_link([]) do
      {:ok, pid} -> Process.unlink(pid)
      {:error, {:already_started, _pid}} -> :ok
    end

    case DiagramStore.start_link([]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    # Make sure no stale :waits entry for this fixture leaks in from a prior run.
    Registry.unregister(:waits, {@tenant, :message, @catch_name, @business_key})

    on_exit(fn ->
      Registry.unregister(:waits, {@tenant, :message, @catch_name, @business_key})
    end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # B5 — loop-back to the same catch mints two distinct wait_ids; the :waits
  # value carries the per-occurrence wait_id (the retention consumption identity).
  # ---------------------------------------------------------------------------

  describe "B5 — loop-back to the same message catch" do
    test "two activations of the SAME catch on the SAME token mint two distinct wait_ids" do
      # First activation: the token reaches the catch and registers a wait.
      state1 = TokenProcessor.process_active_tokens(loopback_state())

      assert [%PersistentData.MessageWaitCreated{name: @catch_name, wait_id: wait_id_a}] =
               state1.persistent_events

      assert is_binary(wait_id_a)
      assert state1.tokens[0].state == :waiting_for_message
      assert state1.wait_ids[{:message, @catch_name, 0}] == wait_id_a

      # The cross-instance :waits registry value carries {token_id, wait_id} — the
      # wait_id is the per-occurrence identity the retention store keys on, NOT a
      # bare token_id (which a loop-back reuses).
      assert [{_pid, {0, ^wait_id_a}}] =
               Registry.lookup(:waits, {@tenant, :message, @catch_name, @business_key})

      # Simulate the durable consumption of activation #1 and the loop back to the
      # SAME catch node: the engine, on MessageHandled, removes that occurrence's
      # open wait (registry + message_waits + wait_ids) and the token re-enters the
      # catch active. We reproduce exactly that pre-condition, then re-run.
      Registry.unregister_match(
        :waits,
        {@tenant, :message, @catch_name, @business_key},
        {0, :_}
      )

      # The token has looped back and re-entered the catch node (1) in the
      # runnable :execute_current_node state, so process_active_tokens re-runs the
      # node's `process` (a fresh wait), exactly as a real loop-back does — NOT
      # :continue (which would advance past the catch via continue_after_wait).
      looped_token = Token.new(0, 0, 1)

      state_for_second = %{
        state1
        | tokens: %{0 => looped_token},
          active_tokens: MapSet.new([0]),
          waiting_tokens: MapSet.delete(state1.waiting_tokens, 0),
          message_waits: %{},
          wait_ids: Map.delete(state1.wait_ids, {:message, @catch_name, 0}),
          persistent_events: []
      }

      # Second activation: the SAME catch, SAME token, SAME node — must mint a NEW id.
      state2 = TokenProcessor.process_active_tokens(state_for_second)

      assert [%PersistentData.MessageWaitCreated{name: @catch_name, wait_id: wait_id_b}] =
               state2.persistent_events

      assert is_binary(wait_id_b)

      # CORE B5 ASSERTION: a loop-back to the same catch does NOT reuse the prior
      # occurrence's id — two activations ⇒ two DISTINCT wait_ids.
      refute wait_id_b == wait_id_a
      assert state2.wait_ids[{:message, @catch_name, 0}] == wait_id_b

      assert [{_pid, {0, ^wait_id_b}}] =
               Registry.lookup(:waits, {@tenant, :message, @catch_name, @business_key})
    end

    test "replay of a full loop consumes the SAME physical message_id once per distinct wait_id" do
      # B5 at the durability layer. A loop-back to the same catch is a SEQUENTIAL
      # series of (MessageWaitCreated -> MessageHandled) occurrences on ONE token:
      # the engine holds at most one open occurrence per {token, name} at an
      # instant (state.wait_ids slot), so the loop replays as activation A,
      # consume A (by wait_id_a), re-activation B, consume B (by wait_id_b). The
      # SAME physical message_id is therefore legitimately consumed once per
      # wait_id. Each MessageHandled removes the open wait BY its persisted wait_id
      # (resolved_wait_ids_from_events keys on event.wait_id, NOT token_id), and
      # the two activations carry DISTINCT wait_ids — the per-occurrence identity
      # the gateway retention store writes one consumption row against.
      definition = loopback_definition("widlr-replay-loop")
      :ok = DiagramStore.register(definition.name, definition.version, @tenant, definition)

      wait_id_a = "widlr-wait-A"
      wait_id_b = "widlr-wait-B"

      refute wait_id_a == wait_id_b

      # --- After the FIRST loop iteration fully replays (A created then A consumed),
      # the catch wait is closed and the consumed occurrence's id is gone. ---
      after_first =
        [
          start_event(definition),
          %PersistentData.TokenFamilyCreated{token: 0, family: 0, current_node: 1},
          %PersistentData.MessageWaitCreated{
            token: 0,
            family: 0,
            current_node: 1,
            name: @catch_name,
            business_key: @business_key,
            wait_id: wait_id_a
          },
          %PersistentData.MessageHandled{
            token: 0,
            family: 0,
            current_node: 1,
            name: @catch_name,
            wait_id: wait_id_a,
            target_node: 1
          }
        ]

      assert {:ok, state_a} =
               EventReplayer.restore_from_events(after_first, restore_state("widlr-inst-1a"))

      # Occurrence A was removed by its wait_id; no open message wait remains.
      refute Map.has_key?(state_a.wait_ids, {:message, @catch_name, 0})
      assert Map.get(state_a.message_waits, @catch_name, []) == []
      assert Registry.lookup(:waits, {@tenant, :message, @catch_name, @business_key}) == []

      # --- The SECOND loop iteration re-activates the SAME catch with a NEW wait_id
      # (B), and (re-)consumes the SAME physical message under B. The whole loop
      # replays cleanly and the second occurrence is keyed by its OWN distinct id. ---
      full_loop =
        after_first ++
          [
            %PersistentData.MessageWaitCreated{
              token: 0,
              family: 0,
              current_node: 1,
              name: @catch_name,
              business_key: @business_key,
              wait_id: wait_id_b
            },
            %PersistentData.MessageHandled{
              token: 0,
              family: 0,
              current_node: 1,
              name: @catch_name,
              wait_id: wait_id_b,
              target_node: 1
            }
          ]

      assert {:ok, state_b} =
               EventReplayer.restore_from_events(full_loop, restore_state("widlr-inst-1b"))

      # Both distinct occurrences replayed and were each consumed by their OWN
      # wait_id — neither leaves a dangling open wait, and the token is active
      # (resumed past the catch), proving per-wait_id consumption across the loop.
      refute Map.has_key?(state_b.wait_ids, {:message, @catch_name, 0})
      assert Map.get(state_b.message_waits, @catch_name, []) == []
      assert MapSet.member?(state_b.active_tokens, 0)
      assert Registry.lookup(:waits, {@tenant, :message, @catch_name, @business_key}) == []

      # --- Mid-second-wait crash: A consumed, then B created but NOT yet consumed.
      # Replay must leave occurrence B OPEN, re-registered under its OWN wait_id
      # (the loop-back's fresh id), NOT the already-consumed wait_id_a. ---
      mid_second =
        after_first ++
          [
            %PersistentData.MessageWaitCreated{
              token: 0,
              family: 0,
              current_node: 1,
              name: @catch_name,
              business_key: @business_key,
              wait_id: wait_id_b
            }
          ]

      assert {:ok, state_mid} =
               EventReplayer.restore_from_events(mid_second, restore_state("widlr-inst-1c"))

      # The open occurrence carries the loop-back's distinct id (B), never the
      # already-consumed A — replay reads the wait_id from the event, never reuses
      # the previous occurrence's id.
      assert state_mid.wait_ids[{:message, @catch_name, 0}] == wait_id_b
      refute state_mid.wait_ids[{:message, @catch_name, 0}] == wait_id_a
      assert state_mid.message_waits[@catch_name] == [0]
      assert MapSet.member?(state_mid.waiting_tokens, 0)

      assert [{_pid, {0, ^wait_id_b}}] =
               Registry.lookup(:waits, {@tenant, :message, @catch_name, @business_key})
    end
  end

  # ---------------------------------------------------------------------------
  # E2 — engine restart / replay mid-wait: the persisted wait_id is re-registered,
  # NOT re-minted.
  # ---------------------------------------------------------------------------

  describe "E2 — replay mid-wait re-registers the persisted wait_id" do
    test "a persisted MessageWaitCreated re-registers the SAME wait_id in :waits (read-not-re-minted)" do
      definition = loopback_definition("widlr-e2-restore")
      :ok = DiagramStore.register(definition.name, definition.version, @tenant, definition)

      persisted_wait_id = "widlr-persisted-wait-E2"

      events = [
        start_event(definition),
        %PersistentData.TokenFamilyCreated{token: 0, family: 0, current_node: 1},
        %PersistentData.MessageWaitCreated{
          token: 0,
          family: 0,
          current_node: 1,
          name: @catch_name,
          business_key: @business_key,
          wait_id: persisted_wait_id
        }
      ]

      assert {:ok, state} = EventReplayer.restore_from_events(events, restore_state("widlr-inst-2"))

      # The token is restored as still waiting on the catch.
      assert state.message_waits[@catch_name] == [0]
      assert MapSet.member?(state.waiting_tokens, 0)
      assert state.tokens[0].state == :waiting_for_message

      # E2 CORE: the in-memory wait_ids index AND the :waits registry value carry
      # the EXACT persisted wait_id — read from the log, never re-minted. A
      # re-minted (fresh UUID) id would mismatch the retention store's key and
      # double-deliver on redelivery; an unstable id would block. Assert identity.
      assert state.wait_ids[{:message, @catch_name, 0}] == persisted_wait_id

      assert [{_pid, {0, ^persisted_wait_id}}] =
               Registry.lookup(:waits, {@tenant, :message, @catch_name, @business_key})
    end
  end

  # ---------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------

  # A single message catch (node 1) whose only output loops straight back to
  # itself (node 1) — the minimal "loop back to the same catch node" shape.
  defp loopback_definition(name) do
    %Definition{
      name: name,
      version: 1,
      nodes: %{
        1 => %Nodes.IntermediateCatch.MessageEvent{
          id: 1,
          message: %{name: @catch_name},
          outputs: [1]
        }
      }
    }
  end

  # Live driving state: token 0 active at the catch node (1), ready for
  # TokenProcessor.process_active_tokens to register the wait and mint a wait_id.
  defp loopback_state do
    definition = loopback_definition("widlr-live-loop")

    Map.merge(TokenState.base_state(), %{
      id: "widlr-inst-live",
      business_key: @business_key,
      tenant_id: @tenant,
      definition: definition,
      tokens: %{0 => Token.new(0, 0, 1)},
      active_tokens: MapSet.new([0]),
      next_token_id: 1
    })
  end

  defp restore_state(instance_id) do
    Map.merge(TokenState.base_state(), %{
      id: instance_id,
      tenant_id: @tenant,
      instance_state: :simulating
    })
  end

  defp start_event(definition) do
    %PersistentData.ProcessInstanceStart{
      process_instance_id: "widlr-inst",
      business_key: @business_key,
      tenant: @tenant,
      process_name: definition.name,
      process_version: definition.version
    }
  end
end
