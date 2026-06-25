defmodule Chronicle.Engine.Instance.EventReplayerEventGatewaySignalTimerE4Test do
  @moduledoc """
  Scenario E4 TWIN for SIGNAL and TIMER winners: crash between
  `SignalHandled`/`TimerElapsed` and `EventGatewayResolved`.

  The MessageHandled twin is covered by
  `event_replayer_event_gateway_e4_test.exs`. A message winner of an
  event-based gateway is already crash-replay durable: on replay of only
  `MessageHandled` the token is set `:continue` with the reconstructed
  continuation trigger and ALL sibling gateway waits are closed.

  A SIGNAL or TIMER winner of the SAME gateway must behave IDENTICALLY. The
  live resume sets the token `:continue` with trigger `{:signal, name}`
  (wait_registry.ex) / `:timer_elapsed` (wait_registry.ex) and closes every
  sibling branch wait; the durable `EventGatewayResolved` that moves the token
  onto the selected branch is appended in a LATER token-processing cycle. We
  simulate a CRASH in that exact window by replaying the persisted log ONLY up
  to (and including) `SignalHandled` / `TimerElapsed` — `EventGatewayResolved`
  is never replayed.

  Post-replay the EventReplayer must guarantee:
    (a) the winner survives — the token resumes via the reconstructed
        continuation trigger for the SELECTED branch, not `:execute_current_node`
        on the gateway node (which would re-arm every branch);
    (b) EXACTLY ONE branch is active — every sibling message/signal/timer wait
        (re-opened by `EventGatewayActivated` replay) is closed, so no sibling
        can double-fire;
    (c) the token CONTINUES (`:continue`, classified active, not stalled in
        `waiting_tokens`), so re-processing deterministically re-appends
        `EventGatewayResolved` onto the selected branch.

  Pure-replay test, no DB. Built on the same harness as
  `event_replayer_event_gateway_e4_test.exs`. Unique tenant/business_key/
  definition/instance names keep it isolated from parallel sibling files and
  from the shared duplicate `:waits` Registry.
  """
  use ExUnit.Case, async: false

  alias Chronicle.Engine.{PersistentData, Nodes, Token}
  alias Chronicle.Engine.Diagrams.{Definition, DiagramStore}
  alias Chronicle.Engine.Instance.{EventReplayer, TokenState}

  @tenant "tenant-e4-st"
  @business_key "bk-e4-st"

  setup do
    case DiagramStore.start_link([]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  # Event-based gateway (node 10) with a message branch (approve, 11), a signal
  # branch (escalate, 12) and a timer branch (timeout, 13), so closing siblings
  # is observable across all three wait kinds.
  defp gateway_definition(name) do
    %Definition{
      name: name,
      version: 1,
      nodes: %{
        10 => %Nodes.Gateway{id: 10, kind: :event_based, outputs: [11, 12, 13]},
        11 => %Nodes.IntermediateCatch.MessageEvent{
          id: 11,
          message: %{name: "approve"},
          outputs: [21]
        },
        12 => %Nodes.IntermediateCatch.SignalEvent{
          id: 12,
          signal: "escalate",
          outputs: [22]
        },
        13 => %Nodes.IntermediateCatch.TimerEvent{
          id: 13,
          timer_config: %{duration_ms: 60_000},
          outputs: [23]
        },
        21 => %Nodes.EndEvents.BlankEndEvent{id: 21},
        22 => %Nodes.EndEvents.BlankEndEvent{id: 22},
        23 => %Nodes.EndEvents.BlankEndEvent{id: 23}
      }
    }
  end

  defp restore_state(instance_id) do
    Map.merge(TokenState.base_state(), %{
      id: instance_id,
      tenant_id: @tenant,
      business_key: @business_key,
      instance_state: :simulating
    })
  end

  defp start_event(definition) do
    %PersistentData.ProcessInstanceStart{
      process_instance_id: "inst",
      business_key: @business_key,
      tenant: @tenant,
      process_name: definition.name,
      process_version: definition.version
    }
  end

  # Token arms the gateway: message candidate "approve", signal candidate
  # "escalate", timer candidate "timer-e4-st-1". The single gateway wait_id is
  # minted by EventGatewayActivated and shared by every candidate.
  defp gateway_activated_events(definition) do
    [
      start_event(definition),
      %PersistentData.TokenFamilyCreated{token: 1, family: 0, current_node: 10},
      %PersistentData.EventGatewayActivated{
        token: 1,
        family: 0,
        current_node: 10,
        message_names: ["approve"],
        signal_names: ["escalate"],
        timer_ids: ["timer-e4-st-1"],
        wait_id: "wait-e4-st-gateway-1"
      }
    ]
  end

  # --- SIGNAL winner -------------------------------------------------------

  test "E4 SIGNAL winner: crash between SignalHandled and EventGatewayResolved closes siblings and continues the signal branch" do
    definition = gateway_definition("e4-st-signal-crash")
    :ok = DiagramStore.register(definition.name, definition.version, @tenant, definition)

    # The signal "escalate" wins the gateway; SignalHandled.target_node is the
    # GATEWAY node itself (instance.ex sets target_node: token.current_node).
    # EventGatewayResolved is NOT yet durable (crash window) -> omitted.
    events =
      gateway_activated_events(definition) ++
        [
          %PersistentData.SignalHandled{
            token: 1,
            family: 0,
            current_node: 10,
            signal_name: "escalate",
            target_node: 10
          }
        ]

    assert {:ok, state} =
             EventReplayer.restore_from_events(events, restore_state("inst-e4-st-signal"))

    token = state.tokens[1]

    # (a) The winner survives: the token resumes with the SAME trigger the live
    # WaitRegistry resumes with for a signal ({:signal, name}), selecting branch 12.
    assert token.context[:continuation_context] == {:signal, "escalate"}

    # (b) EXACTLY ONE branch active — every sibling wait closed.
    assert state.message_waits == %{}
    assert state.signal_waits == %{}
    refute Map.has_key?(state.wait_ids, {:gateway, 1})
    assert Registry.lookup(:waits, {@tenant, :message, "approve", @business_key}) == []
    assert Registry.lookup(:waits, {@tenant, :signal, "escalate"}) == []
    assert map_size(state.tokens) == 1
    assert MapSet.size(state.active_tokens) == 1

    # (c) The token CONTINUES — :continue, active, not stalled, still on the
    # gateway node so continue_after_wait re-appends EventGatewayResolved (branch 12).
    assert token.state == :continue
    assert Token.active?(token)
    refute Token.terminal?(token)
    assert MapSet.member?(state.active_tokens, 1)
    refute MapSet.member?(state.waiting_tokens, 1)
    refute MapSet.member?(state.completed_tokens, 1)
    assert token.current_node == 10
  end

  test "E4 SIGNAL control: full log including EventGatewayResolved reaches the signal branch and closes siblings" do
    definition = gateway_definition("e4-st-signal-resolved")
    :ok = DiagramStore.register(definition.name, definition.version, @tenant, definition)

    events =
      gateway_activated_events(definition) ++
        [
          %PersistentData.SignalHandled{
            token: 1,
            family: 0,
            current_node: 10,
            signal_name: "escalate",
            target_node: 10
          },
          %PersistentData.EventGatewayResolved{
            token: 1,
            family: 0,
            current_node: 10,
            trigger_type: :signal,
            trigger_name: "escalate",
            selected_node: 12,
            target_node: 22,
            wait_id: "wait-e4-st-gateway-1"
          }
        ]

    assert {:ok, state} =
             EventReplayer.restore_from_events(events, restore_state("inst-e4-st-signal-resolved"))

    token = state.tokens[1]

    assert state.message_waits == %{}
    assert state.signal_waits == %{}
    assert token.current_node == 22
    assert MapSet.member?(state.active_tokens, 1)
    refute MapSet.member?(state.waiting_tokens, 1)
    assert Registry.lookup(:waits, {@tenant, :message, "approve", @business_key}) == []
    assert Registry.lookup(:waits, {@tenant, :signal, "escalate"}) == []
  end

  # --- TIMER winner --------------------------------------------------------

  test "E4 TIMER winner: crash between TimerElapsed and EventGatewayResolved closes siblings and continues the timer branch" do
    definition = gateway_definition("e4-st-timer-crash")
    :ok = DiagramStore.register(definition.name, definition.version, @tenant, definition)

    # The gateway timer candidate first persists TimerCreated, then TimerElapsed
    # when it WINS; TimerElapsed.target_node is the gateway node itself (the timer
    # candidate's TimerCreated.target_node is token.current_node). The durable
    # EventGatewayResolved is NOT yet appended (crash window) -> omitted.
    events =
      gateway_activated_events(definition) ++
        [
          %PersistentData.TimerCreated{
            token: 1,
            family: 0,
            current_node: 10,
            timer_id: "timer-e4-st-1",
            trigger_at: System.system_time(:millisecond) + 60_000,
            target_node: 10
          },
          %PersistentData.TimerElapsed{
            token: 1,
            family: 0,
            current_node: 10,
            timer_id: "timer-e4-st-1",
            target_node: 10
          }
        ]

    assert {:ok, state} =
             EventReplayer.restore_from_events(events, restore_state("inst-e4-st-timer"))

    token = state.tokens[1]

    # (a) The winner survives: the token resumes with the SAME trigger the live
    # WaitRegistry resumes with for a timer (:timer_elapsed), selecting branch 13.
    assert token.context[:continuation_context] == :timer_elapsed

    # (b) EXACTLY ONE branch active — every sibling wait closed, and the gateway
    # timer registration drained (no open timer would re-arm a sibling).
    assert state.message_waits == %{}
    assert state.signal_waits == %{}
    refute Map.has_key?(state.wait_ids, {:gateway, 1})
    assert Registry.lookup(:waits, {@tenant, :message, "approve", @business_key}) == []
    assert Registry.lookup(:waits, {@tenant, :signal, "escalate"}) == []
    assert map_size(state.tokens) == 1
    assert MapSet.size(state.active_tokens) == 1

    # (c) The token CONTINUES — :continue, active, not stalled, still on the
    # gateway node so continue_after_wait re-appends EventGatewayResolved (branch 13).
    assert token.state == :continue
    assert Token.active?(token)
    refute Token.terminal?(token)
    assert MapSet.member?(state.active_tokens, 1)
    refute MapSet.member?(state.waiting_tokens, 1)
    refute MapSet.member?(state.completed_tokens, 1)
    assert token.current_node == 10
  end

  test "E4 TIMER control: full log including EventGatewayResolved reaches the timer branch and closes siblings" do
    definition = gateway_definition("e4-st-timer-resolved")
    :ok = DiagramStore.register(definition.name, definition.version, @tenant, definition)

    events =
      gateway_activated_events(definition) ++
        [
          %PersistentData.TimerCreated{
            token: 1,
            family: 0,
            current_node: 10,
            timer_id: "timer-e4-st-1",
            trigger_at: System.system_time(:millisecond) + 60_000,
            target_node: 10
          },
          %PersistentData.TimerElapsed{
            token: 1,
            family: 0,
            current_node: 10,
            timer_id: "timer-e4-st-1",
            target_node: 10
          },
          %PersistentData.EventGatewayResolved{
            token: 1,
            family: 0,
            current_node: 10,
            trigger_type: :timer,
            trigger_name: nil,
            selected_node: 13,
            target_node: 23,
            wait_id: "wait-e4-st-gateway-1"
          }
        ]

    assert {:ok, state} =
             EventReplayer.restore_from_events(events, restore_state("inst-e4-st-timer-resolved"))

    token = state.tokens[1]

    assert state.message_waits == %{}
    assert state.signal_waits == %{}
    assert token.current_node == 23
    assert MapSet.member?(state.active_tokens, 1)
    refute MapSet.member?(state.waiting_tokens, 1)
    assert Registry.lookup(:waits, {@tenant, :message, "approve", @business_key}) == []
    assert Registry.lookup(:waits, {@tenant, :signal, "escalate"}) == []
  end

  # --- MESSAGE winner re-confirm (the already-fixed twin still passes) -----

  test "E4 MESSAGE winner re-confirm: crash between MessageHandled and EventGatewayResolved still closes siblings and continues" do
    definition = gateway_definition("e4-st-message-crash")
    :ok = DiagramStore.register(definition.name, definition.version, @tenant, definition)

    events =
      gateway_activated_events(definition) ++
        [
          %PersistentData.MessageHandled{
            token: 1,
            family: 0,
            current_node: 10,
            name: "approve",
            target_node: 10,
            payload: %{"decision" => "approve"},
            wait_id: "wait-e4-st-gateway-1",
            selected_node: 11
          }
        ]

    assert {:ok, state} =
             EventReplayer.restore_from_events(events, restore_state("inst-e4-st-message"))

    token = state.tokens[1]

    assert token.context[:continuation_context] ==
             {:message, "approve", %{"decision" => "approve"}, 11}

    assert state.message_waits == %{}
    assert state.signal_waits == %{}
    refute Map.has_key?(state.wait_ids, {:gateway, 1})
    assert token.state == :continue
    assert MapSet.member?(state.active_tokens, 1)
    refute MapSet.member?(state.waiting_tokens, 1)
    assert token.current_node == 10
  end
end
