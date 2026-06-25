defmodule Chronicle.Engine.Instance.EventReplayerEventGatewayE4Test do
  @moduledoc """
  Scenario E4 (inbox-redesign-plan / inbox-scenarios): crash between
  `MessageHandled` and `EventGatewayResolved`.

  A message that selects an event-based gateway branch persists
  `MessageHandled{selected_node: branch}` (`instance.ex`), but the
  `EventGatewayResolved` that actually moves the token onto the selected
  branch is appended in a LATER token-processing cycle. We simulate a CRASH
  in that exact window by replaying the persisted log ONLY up to (and
  including) `MessageHandled` — `EventGatewayResolved` is never replayed.

  The redesign (`event_replayer.ex` MessageHandled clause) must guarantee
  post-replay:
    (a) the consumed message survives the crash — its data is preserved into
        the durable continuation trigger, not lost;
    (b) EXACTLY ONE branch is active — every sibling gateway wait
        (re-opened by `EventGatewayActivated` replay) is closed, so no
        sibling can double-fire;
    (c) the selected branch CONTINUES — the token is set to resume
        (`:continue` + selected branch in the continuation trigger), classified
        active (not stalled in `waiting_tokens`), so re-processing deterministically
        re-appends `EventGatewayResolved` onto the selected branch.

  Pure-replay test built on the same harness as
  `event_replayer_boundary_test.exs` (`EventReplayer.restore_from_events/2`,
  `DiagramStore`, `restore_state/1`). No DB. Unique tenant/business_key/
  definition/instance names keep it isolated from parallel sibling files and
  from the shared duplicate `:waits` Registry.
  """
  use ExUnit.Case, async: false

  alias Chronicle.Engine.{PersistentData, Nodes, Token}
  alias Chronicle.Engine.Diagrams.{Definition, DiagramStore}
  alias Chronicle.Engine.Instance.{EventReplayer, TokenState}

  @tenant "tenant-e4"
  @business_key "bk-e4"

  setup do
    case DiagramStore.start_link([]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  # Event-based gateway (node 10) with TWO message branches + one timer branch,
  # so closing siblings is observable: approve(11), reject(12), timeout(13).
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
        12 => %Nodes.IntermediateCatch.MessageEvent{
          id: 12,
          message: %{name: "reject"},
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

  # Log replayed on crash: token arms the event gateway, then the "approve"
  # message is delivered (MessageHandled with selected_node: 11). The crash
  # happens BEFORE EventGatewayResolved is appended, so it is omitted.
  defp events_up_to_message_handled(definition) do
    [
      start_event(definition),
      %PersistentData.TokenFamilyCreated{token: 1, family: 0, current_node: 10},
      %PersistentData.EventGatewayActivated{
        token: 1,
        family: 0,
        current_node: 10,
        message_names: ["approve", "reject"],
        timer_ids: ["timer-e4-1"],
        wait_id: "wait-e4-gateway-1"
      },
      # The arbiter persists MessageHandled for the selected gateway branch.
      # target_node is the GATEWAY node itself (instance.ex sets
      # target_node: token.current_node); selected_node names the chosen branch.
      %PersistentData.MessageHandled{
        token: 1,
        family: 0,
        current_node: 10,
        name: "approve",
        target_node: 10,
        payload: %{"decision" => "approve", "approver" => "alice"},
        wait_id: "wait-e4-gateway-1",
        selected_node: 11
      }
    ]
  end

  test "E4: crash between MessageHandled and EventGatewayResolved keeps message, closes siblings, continues selected branch" do
    definition = gateway_definition("e4-event-gateway-crash")
    :ok = DiagramStore.register(definition.name, definition.version, @tenant, definition)

    events = events_up_to_message_handled(definition)

    assert {:ok, state} =
             EventReplayer.restore_from_events(events, restore_state("inst-e4-crash"))

    token = state.tokens[1]

    # ---- (a) the consumed message SURVIVES the crash ----------------------
    # The delivery's name + payload + selected branch are preserved into the
    # durable continuation trigger, so re-processing replays the same delivery
    # the live WaitRegistry would have — the message is NOT lost.
    assert token.context[:continuation_context] ==
             {:message, "approve", %{"decision" => "approve", "approver" => "alice"}, 11}

    # ---- (b) EXACTLY ONE branch active — siblings closed (no double-fire) --
    # EventGatewayActivated replay re-opened BOTH "approve" and "reject" message
    # waits for this token; the MessageHandled gateway clause must close ALL of
    # them (not just the consumed "approve"). No open message wait survives, so
    # no sibling branch can fire.
    assert state.message_waits == %{}
    assert state.signal_waits == %{}

    # The gateway wait_id index for this token is forgotten (resolved exactly once).
    refute Map.has_key?(state.wait_ids, {:gateway, 1})

    # Nothing re-registers in the shared :waits Registry for the closed siblings.
    assert Registry.lookup(:waits, {@tenant, :message, "approve", @business_key}) == []
    assert Registry.lookup(:waits, {@tenant, :message, "reject", @business_key}) == []

    # Exactly one token, and it is the live one — no orphaned sibling tokens.
    assert map_size(state.tokens) == 1
    assert MapSet.size(state.active_tokens) == 1

    # ---- (c) the SELECTED branch CONTINUES — not stalled, not double-fired -
    # The token resumes via :continue (dispatched to continue_after_wait, which
    # selects branch 11 and re-appends EventGatewayResolved) rather than
    # re-executing the gateway node (which would re-arm every branch).
    assert token.state == :continue
    assert Token.active?(token)
    refute Token.terminal?(token)

    # Active, NOT waiting/stalled.
    assert MapSet.member?(state.active_tokens, 1)
    refute MapSet.member?(state.waiting_tokens, 1)
    refute MapSet.member?(state.completed_tokens, 1)

    # The token still sits on the gateway node so continue_after_wait re-derives
    # and durably re-appends EventGatewayResolved onto the SELECTED branch (11).
    assert token.current_node == 10
    assert match?({:message, "approve", _payload, 11}, token.context[:continuation_context])
  end

  test "E4 control: full log including EventGatewayResolved reaches the selected branch and closes siblings" do
    # Anchors the crash assertions against the NON-crash path: when
    # EventGatewayResolved IS durable, the token advances onto the selected
    # branch continuation (node 21) and is plainly active — proving the crash
    # case continues toward the SAME outcome (selected branch), never the
    # sibling and never a stall.
    definition = gateway_definition("e4-event-gateway-resolved")
    :ok = DiagramStore.register(definition.name, definition.version, @tenant, definition)

    events =
      events_up_to_message_handled(definition) ++
        [
          %PersistentData.EventGatewayResolved{
            token: 1,
            family: 0,
            current_node: 10,
            trigger_type: :message,
            trigger_name: "approve",
            selected_node: 11,
            target_node: 21,
            payload: %{"decision" => "approve", "approver" => "alice"},
            wait_id: "wait-e4-gateway-1"
          }
        ]

    assert {:ok, state} =
             EventReplayer.restore_from_events(events, restore_state("inst-e4-resolved"))

    token = state.tokens[1]

    # Siblings closed, single active token on the selected branch continuation.
    assert state.message_waits == %{}
    assert state.signal_waits == %{}
    assert token.current_node == 21
    assert MapSet.member?(state.active_tokens, 1)
    refute MapSet.member?(state.waiting_tokens, 1)
    assert Registry.lookup(:waits, {@tenant, :message, "approve", @business_key}) == []
    assert Registry.lookup(:waits, {@tenant, :message, "reject", @business_key}) == []
  end
end
