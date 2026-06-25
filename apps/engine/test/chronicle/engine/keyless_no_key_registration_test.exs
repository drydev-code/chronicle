defmodule Chronicle.Engine.KeylessNoKeyRegistrationTest do
  @moduledoc """
  Scenario C1 (engine) — `:no_key` secondary-index registration for the opt-in
  keyless-correlation annotation (plan B'.5, `inbox-redesign-plan.md`;
  `inbox-scenarios.md` row C1).

  Asserts that the engine registers a SECOND `:waits` entry under
  `{tenant, :message, name, :no_key}` (alongside the keyed
  `{tenant, :message, name, business_key}` entry) at the wait sites for:

    * a declared-keyless intermediate message catch, and
    * a declared-keyless event-gateway message branch, and
    * a declared-keyless message boundary (the nested/boundary site the plan
      calls out as the C1 gap),

  and does NOT register `:no_key` for a keyed (un-annotated) catch.

  It then asserts the same `:no_key` registration is reproduced on replay/restore
  (`EventReplayer.restore_from_events`) for both an intermediate catch and an
  event-gateway message branch, and is absent on replay of a keyed catch.

  A catch is "declared keyless" only when its parsed `message` map carries
  `allow_keyless: true` (`token_processor.ex` `message_keyless?/1`); it cannot be
  inferred from an absent correlation predicate.

  Harness mirrors `token_processor_bpmn_features_test.exs` (live registration via
  `TokenProcessor.process_active_tokens/1`) and `event_replayer_boundary_test.exs`
  (replay via `EventReplayer.restore_from_events/2`). The shared `:duplicate`
  `:waits` registry is started by `test_helper.exs`; every fixture below uses a
  unique tenant id / business key / message name (prefix `c1nokey_`) so parallel
  sibling test files do not collide on registry keys.
  """
  use ExUnit.Case, async: false

  alias Chronicle.Engine.{PersistentData, Token, TokenProcessor}
  alias Chronicle.Engine.Diagrams.{Definition, DiagramStore}
  alias Chronicle.Engine.Instance.{EventReplayer, TokenState}
  alias Chronicle.Engine.Nodes

  @tenant "c1nokey_tenant"
  @business_key "c1nokey_bk"

  setup do
    # :waits / PubSub / repo are started by test_helper.exs. The ScriptPool and
    # DiagramStore are started lazily by individual test files.
    case Chronicle.Engine.Scripting.ScriptPool.start_link([]) do
      {:ok, pid} -> Process.unlink(pid)
      {:error, {:already_started, _pid}} -> :ok
    end

    case DiagramStore.start_link([]) do
      {:ok, pid} -> Process.unlink(pid)
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Live registration (TokenProcessor.process_active_tokens)
  # ---------------------------------------------------------------------------

  describe "live :no_key registration at the wait sites" do
    test "declared-keyless intermediate message catch registers under :no_key AND the keyed index" do
      name = "c1nokey_intermediate_keyless"

      state =
        base_state(%{
          1 => %Nodes.IntermediateCatch.MessageEvent{
            id: 1,
            message: %{name: name, allow_keyless: true},
            outputs: [2]
          },
          2 => %Nodes.EndEvents.BlankEndEvent{id: 2}
        })

      state = TokenProcessor.process_active_tokens(state)

      # Token is parked on the message wait.
      assert state.message_waits == %{name => [0]}

      # Keyed entry is always present.
      assert [{_pid, {0, keyed_wait_id}}] =
               Registry.lookup(:waits, {@tenant, :message, name, @business_key})

      assert is_binary(keyed_wait_id)

      # The opt-in :no_key secondary entry carries the SAME durable wait_id.
      assert [{_pid, {0, no_key_wait_id}}] =
               Registry.lookup(:waits, {@tenant, :message, name, :no_key})

      assert no_key_wait_id == keyed_wait_id
    end

    test "keyed (un-annotated) intermediate catch does NOT register under :no_key" do
      name = "c1nokey_intermediate_keyed"

      state =
        base_state(%{
          1 => %Nodes.IntermediateCatch.MessageEvent{
            id: 1,
            # No allow_keyless flag => keyed wait, must never join :no_key.
            message: %{name: name, correlation: "message.status === 'ok'"},
            outputs: [2]
          },
          2 => %Nodes.EndEvents.BlankEndEvent{id: 2}
        })

      state = TokenProcessor.process_active_tokens(state)

      assert state.message_waits == %{name => [0]}

      # Keyed index present.
      assert [{_pid, {0, _wait_id}}] =
               Registry.lookup(:waits, {@tenant, :message, name, @business_key})

      # :no_key index must be empty for a keyed catch.
      assert Registry.lookup(:waits, {@tenant, :message, name, :no_key}) == []
    end

    test "declared-keyless event-gateway message branch registers under :no_key; keyed sibling branch does not" do
      keyless_name = "c1nokey_gw_keyless"
      keyed_name = "c1nokey_gw_keyed"

      state =
        base_state(%{
          1 => %Nodes.Gateway{id: 1, kind: :event_based, outputs: [2, 3]},
          2 => %Nodes.IntermediateCatch.MessageEvent{
            id: 2,
            message: %{name: keyless_name, allow_keyless: true},
            outputs: [4]
          },
          3 => %Nodes.IntermediateCatch.MessageEvent{
            id: 3,
            # Keyed branch on the SAME gateway: must NOT join :no_key.
            message: %{name: keyed_name},
            outputs: [5]
          },
          4 => %Nodes.EndEvents.BlankEndEvent{id: 4},
          5 => %Nodes.EndEvents.BlankEndEvent{id: 5}
        })

      state = TokenProcessor.process_active_tokens(state)

      assert [%PersistentData.EventGatewayActivated{}] = state.persistent_events
      assert state.tokens[0].state == :waiting_for_event_gateway

      # Both branches keyed; both share the single gateway wait_id.
      assert [{_pid, {0, gw_wait_id}}] =
               Registry.lookup(:waits, {@tenant, :message, keyless_name, @business_key})

      assert [{_pid, {0, ^gw_wait_id}}] =
               Registry.lookup(:waits, {@tenant, :message, keyed_name, @business_key})

      # Only the keyless branch joins :no_key, carrying the same gateway wait_id.
      assert [{_pid, {0, ^gw_wait_id}}] =
               Registry.lookup(:waits, {@tenant, :message, keyless_name, :no_key})

      assert Registry.lookup(:waits, {@tenant, :message, keyed_name, :no_key}) == []
    end

    test "declared-keyless message boundary registers under :no_key (the nested/boundary C1 gap)" do
      keyless_name = "c1nokey_boundary_keyless"
      keyed_name = "c1nokey_boundary_keyed"

      state =
        base_state(%{
          1 => %Nodes.ExternalTask{
            id: 1,
            kind: :service,
            outputs: [2],
            boundary_events: [
              %Nodes.BoundaryEvents.MessageBoundary{
                id: 20,
                message: %{name: keyless_name, allow_keyless: true},
                outputs: [30]
              },
              %Nodes.BoundaryEvents.MessageBoundary{
                id: 21,
                message: %{name: keyed_name},
                outputs: [31]
              }
            ]
          },
          2 => %Nodes.EndEvents.BlankEndEvent{id: 2},
          30 => %Nodes.EndEvents.BlankEndEvent{id: 30},
          31 => %Nodes.EndEvents.BlankEndEvent{id: 31}
        })

      state = TokenProcessor.process_active_tokens(state)

      # External task is parked waiting; its message boundaries are registered.
      assert state.tokens[0].state == :waiting_for_external_task

      # Keyed index present for both boundaries (boundary value shape:
      # {:boundary, token_id, boundary_id, wait_id}).
      assert [{_pid, {:boundary, 0, 20, keyless_wait_id}}] =
               Registry.lookup(:waits, {@tenant, :message, keyless_name, @business_key})

      assert [{_pid, {:boundary, 0, 21, _keyed_wait_id}}] =
               Registry.lookup(:waits, {@tenant, :message, keyed_name, @business_key})

      # Only the declared-keyless boundary joins :no_key, with the same wait_id.
      assert [{_pid, {:boundary, 0, 20, ^keyless_wait_id}}] =
               Registry.lookup(:waits, {@tenant, :message, keyless_name, :no_key})

      assert Registry.lookup(:waits, {@tenant, :message, keyed_name, :no_key}) == []
    end
  end

  # ---------------------------------------------------------------------------
  # Replay / restore (EventReplayer.restore_from_events)
  # ---------------------------------------------------------------------------

  describe "replay re-registers :no_key the same way" do
    test "restored declared-keyless intermediate catch re-registers under :no_key with the persisted wait_id" do
      name = "c1nokey_replay_intermediate_keyless"

      definition = %Definition{
        name: "c1nokey-replay-intermediate-keyless",
        version: 1,
        nodes: %{
          10 => %Nodes.IntermediateCatch.MessageEvent{
            id: 10,
            message: %{name: name, allow_keyless: true},
            outputs: [11]
          },
          11 => %Nodes.EndEvents.BlankEndEvent{id: 11}
        }
      }

      :ok = DiagramStore.register(definition.name, definition.version, @tenant, definition)

      persisted_wait_id = "c1nokey-wait-intermediate"

      events = [
        start_event(definition),
        %PersistentData.TokenFamilyCreated{token: 1, family: 0, current_node: 10},
        %PersistentData.MessageWaitCreated{
          token: 1,
          family: 0,
          current_node: 10,
          name: name,
          business_key: @business_key,
          wait_id: persisted_wait_id
        }
      ]

      assert {:ok, state} = EventReplayer.restore_from_events(events, restore_state("c1nokey-i1"))

      assert state.tokens[1].state == :waiting_for_message
      assert state.message_waits == %{name => [1]}

      # Keyed entry restored with the persisted wait_id.
      assert [{_pid, {1, ^persisted_wait_id}}] =
               Registry.lookup(:waits, {@tenant, :message, name, @business_key})

      # :no_key entry restored identically.
      assert [{_pid, {1, ^persisted_wait_id}}] =
               Registry.lookup(:waits, {@tenant, :message, name, :no_key})
    end

    test "restored keyed (un-annotated) catch does NOT re-register under :no_key" do
      name = "c1nokey_replay_intermediate_keyed"

      definition = %Definition{
        name: "c1nokey-replay-intermediate-keyed",
        version: 1,
        nodes: %{
          10 => %Nodes.IntermediateCatch.MessageEvent{
            id: 10,
            message: %{name: name},
            outputs: [11]
          },
          11 => %Nodes.EndEvents.BlankEndEvent{id: 11}
        }
      }

      :ok = DiagramStore.register(definition.name, definition.version, @tenant, definition)

      events = [
        start_event(definition),
        %PersistentData.TokenFamilyCreated{token: 1, family: 0, current_node: 10},
        %PersistentData.MessageWaitCreated{
          token: 1,
          family: 0,
          current_node: 10,
          name: name,
          business_key: @business_key,
          wait_id: "c1nokey-wait-keyed"
        }
      ]

      assert {:ok, state} = EventReplayer.restore_from_events(events, restore_state("c1nokey-i2"))

      assert state.message_waits == %{name => [1]}

      assert [{_pid, {1, _wait_id}}] =
               Registry.lookup(:waits, {@tenant, :message, name, @business_key})

      # Keyed catch must stay out of the :no_key index on restore.
      assert Registry.lookup(:waits, {@tenant, :message, name, :no_key}) == []
    end

    test "restored declared-keyless event-gateway message branch re-registers under :no_key" do
      keyless_name = "c1nokey_replay_gw_keyless"
      keyed_name = "c1nokey_replay_gw_keyed"

      definition = %Definition{
        name: "c1nokey-replay-gateway",
        version: 1,
        nodes: %{
          10 => %Nodes.Gateway{id: 10, kind: :event_based, outputs: [11, 12]},
          11 => %Nodes.IntermediateCatch.MessageEvent{
            id: 11,
            message: %{name: keyless_name, allow_keyless: true},
            outputs: [13]
          },
          12 => %Nodes.IntermediateCatch.MessageEvent{
            id: 12,
            message: %{name: keyed_name},
            outputs: [14]
          },
          13 => %Nodes.EndEvents.BlankEndEvent{id: 13},
          14 => %Nodes.EndEvents.BlankEndEvent{id: 14}
        }
      }

      :ok = DiagramStore.register(definition.name, definition.version, @tenant, definition)

      gateway_wait_id = "c1nokey-wait-gateway"

      events = [
        start_event(definition),
        %PersistentData.TokenFamilyCreated{token: 1, family: 0, current_node: 10},
        %PersistentData.EventGatewayActivated{
          token: 1,
          family: 0,
          current_node: 10,
          message_names: [keyless_name, keyed_name],
          signal_names: [],
          timer_ids: [],
          wait_id: gateway_wait_id
        }
      ]

      assert {:ok, state} = EventReplayer.restore_from_events(events, restore_state("c1nokey-g1"))

      assert state.tokens[1].state == :waiting_for_event_gateway

      # Both branches restored under their keyed indexes.
      assert [{_pid, {1, _}}] =
               Registry.lookup(:waits, {@tenant, :message, keyless_name, @business_key})

      assert [{_pid, {1, _}}] =
               Registry.lookup(:waits, {@tenant, :message, keyed_name, @business_key})

      # Only the keyless gateway branch re-registers under :no_key. This is the
      # nested-catch restore gap the plan flags: on restore the token sits on the
      # GATEWAY node, so the replayer must consult the candidate branch node's
      # annotation (not token.current_node) to reproduce :no_key.
      assert [{_pid, {1, _}}] =
               Registry.lookup(:waits, {@tenant, :message, keyless_name, :no_key})

      assert Registry.lookup(:waits, {@tenant, :message, keyed_name, :no_key}) == []
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers (mirrors token_processor_bpmn_features_test.exs / event_replayer_boundary_test.exs)
  # ---------------------------------------------------------------------------

  defp base_state(nodes) do
    token = Token.new(0, 0, 1)

    definition = %Definition{
      name: "c1nokey-features",
      version: 1,
      nodes: nodes
    }

    Map.merge(TokenState.base_state(), %{
      id: "c1nokey-inst",
      business_key: @business_key,
      tenant_id: @tenant,
      definition: definition,
      tokens: %{0 => token},
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
      process_instance_id: "c1nokey-inst",
      business_key: @business_key,
      tenant: @tenant,
      process_name: definition.name,
      process_version: definition.version
    }
  end
end
