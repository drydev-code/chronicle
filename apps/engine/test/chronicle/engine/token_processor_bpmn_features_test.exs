defmodule Chronicle.Engine.TokenProcessorBpmnFeaturesTest do
  use ExUnit.Case, async: true

  alias Chronicle.Engine.{PersistentData, Token, TokenProcessor}
  alias Chronicle.Engine.Diagrams.Definition
  alias Chronicle.Engine.Instance.TokenState
  alias Chronicle.Engine.Nodes

  test "manual task is an explicit persisted no-op transition" do
    state =
      base_state(%{
        1 => %Nodes.Tasks.ManualTask{id: 1, outputs: [2]},
        2 => %Nodes.EndEvents.BlankEndEvent{id: 2}
      })

    state = TokenProcessor.process_active_tokens(state)

    assert [%PersistentData.NoOpTaskCompleted{task_type: :manual_task, target_node: 2}] =
             state.persistent_events

    assert state.tokens[0].state == :move_to_next_node
    assert state.tokens[0].next_node == 2
  end

  test "event-based gateway creates durable waits for message and signal branches" do
    state =
      base_state(%{
        1 => %Nodes.Gateway{id: 1, kind: :event_based, outputs: [2, 3]},
        2 => %Nodes.IntermediateCatch.MessageEvent{
          id: 2,
          message: %{name: "approved"},
          outputs: [4]
        },
        3 => %Nodes.IntermediateCatch.SignalEvent{id: 3, signal: "cancelled", outputs: [5]},
        4 => %Nodes.EndEvents.BlankEndEvent{id: 4},
        5 => %Nodes.EndEvents.BlankEndEvent{id: 5}
      })

    state = TokenProcessor.process_active_tokens(state)

    assert [%PersistentData.EventGatewayActivated{} = event] = state.persistent_events
    assert event.message_names == ["approved"]
    assert event.signal_names == ["cancelled"]
    assert state.message_waits == %{"approved" => [0]}
    assert state.signal_waits == %{"cancelled" => [0]}
    assert state.tokens[0].state == :waiting_for_event_gateway
    assert MapSet.member?(state.waiting_tokens, 0)
  end

  test "event-based gateway crashes instead of filtering unsupported runtime branches" do
    state =
      base_state(%{
        1 => %Nodes.Gateway{id: 1, kind: :event_based, outputs: [2, 3]},
        2 => %Nodes.IntermediateCatch.MessageEvent{
          id: 2,
          message: %{name: "approved"},
          outputs: [4]
        },
        3 => %Nodes.ScriptTask{id: 3, script: "return {};", outputs: [4]},
        4 => %Nodes.EndEvents.BlankEndEvent{id: 4}
      })

    state = TokenProcessor.process_active_tokens(state)

    assert state.tokens[0].state == :crashed
    assert state.persistent_events == []
  end

  test "event-based gateway cancels losing timer branches before resolving message branch" do
    state =
      base_state(%{
        1 => %Nodes.Gateway{id: 1, kind: :event_based, outputs: [2, 3]},
        2 => %Nodes.IntermediateCatch.MessageEvent{
          id: 2,
          message: %{name: "approved"},
          outputs: [4]
        },
        3 => %Nodes.IntermediateCatch.TimerEvent{
          id: 3,
          timer_config: %{duration_ms: 60_000},
          outputs: [5]
        },
        4 => %Nodes.EndEvents.BlankEndEvent{id: 4},
        5 => %Nodes.EndEvents.BlankEndEvent{id: 5}
      })

    waiting_state = TokenProcessor.process_active_tokens(state)
    token = Token.continue(waiting_state.tokens[0])
    token = Token.set_context(token, :continuation_context, {:message, "approved", %{}})

    resumed_state = %{
      waiting_state
      | tokens: Map.put(waiting_state.tokens, 0, token),
        waiting_tokens: MapSet.delete(waiting_state.waiting_tokens, 0),
        active_tokens: MapSet.new([0])
    }

    final_state = TokenProcessor.process_active_tokens(resumed_state)

    assert [
             %PersistentData.TimerCreated{timer_id: timer_id},
             %PersistentData.EventGatewayActivated{},
             %PersistentData.TimerCanceled{timer_id: canceled_timer_id},
             %PersistentData.EventGatewayResolved{selected_node: 2, target_node: 4}
           ] = final_state.persistent_events

    assert canceled_timer_id == timer_id

    assert final_state.timer_refs == %{}
  end

  test "conditional catch false wait can be durably re-evaluated to continue" do
    state =
      base_state(%{
        1 => %Nodes.IntermediateCatch.ConditionalEvent{
          id: 1,
          condition: "ready === true",
          outputs: [2]
        },
        2 => %Nodes.EndEvents.BlankEndEvent{id: 2}
      })

    token = Token.continue(state.tokens[0])
    token = Token.set_context(token, :continuation_context, {:ok, [%{"node_id" => 1, "result" => false}]})

    waiting_state =
      state
      |> Map.put(:tokens, %{0 => token})
      |> TokenProcessor.process_active_tokens()

    token = Token.continue(waiting_state.tokens[0])
    token = Token.set_context(token, :continuation_context, {:ok, [%{"node_id" => 1, "result" => true}]})

    resumed_state = %{
      waiting_state
      | tokens: Map.put(waiting_state.tokens, 0, token),
        waiting_tokens: MapSet.delete(waiting_state.waiting_tokens, 0),
        active_tokens: MapSet.new([0])
    }

    final_state = TokenProcessor.process_active_tokens(resumed_state)

    assert [
             %PersistentData.ConditionalEventEvaluated{matched: false},
             %PersistentData.ConditionalEventWaitCreated{},
             %PersistentData.ConditionalEventEvaluated{matched: true, target_node: 2}
           ] = final_state.persistent_events

    assert final_state.tokens[0].next_node == 2
  end

  test "token crash appends boundary cancellations before closing registrations" do
    ref = make_ref()

    state =
      base_state(%{})
      |> Map.put(:boundary_index, %{
        0 => [
          %{
            type: :message,
            boundary_node_id: 20,
            name: "cancel",
            interrupting: true
          },
          %{
            type: :timer,
            boundary_node_id: 21,
            timer_id: "boundary-timer",
            timer_ref: ref,
            interrupting: true
          }
        ]
      })
      |> Map.put(:timer_refs, %{ref => 0})
      |> Map.put(:timer_ref_ids, %{ref => "boundary-timer"})

    state = TokenProcessor.process_active_tokens(state)

    assert [
             %PersistentData.BoundaryEventCancelled{boundary_node_id: 20},
             %PersistentData.BoundaryEventCancelled{
               boundary_node_id: 21,
               timer_id: "boundary-timer"
             }
           ] = state.persistent_events

    assert state.boundary_index == %{}
    assert state.timer_refs == %{}
    assert state.tokens[0].state == :crashed
  end

  test "link throw records the jump to its catch event" do
    state =
      base_state(%{
        1 => %Nodes.IntermediateThrow.LinkEvent{id: 1, link_name: "continue"},
        2 => %Nodes.IntermediateCatch.LinkEvent{id: 2, link_name: "continue", outputs: [3]},
        3 => %Nodes.EndEvents.BlankEndEvent{id: 3}
      })

    state = TokenProcessor.process_active_tokens(state)

    assert [%PersistentData.LinkTraversed{link_name: "continue", target_node: 2}] =
             state.persistent_events

    assert state.tokens[0].next_node == 2
  end

  defp base_state(nodes) do
    token = Token.new(0, 0, 1)

    definition = %Definition{
      name: "bpmn-features",
      version: 1,
      nodes: nodes
    }

    Map.merge(TokenState.base_state(), %{
      id: "inst",
      business_key: "bk",
      tenant_id: "tenant",
      definition: definition,
      tokens: %{0 => token},
      active_tokens: MapSet.new([0]),
      next_token_id: 1
    })
  end
end
