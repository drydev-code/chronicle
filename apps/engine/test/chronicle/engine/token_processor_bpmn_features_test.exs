defmodule Chronicle.Engine.TokenProcessorBpmnFeaturesTest do
  use ExUnit.Case, async: false

  alias Chronicle.Engine.{PersistentData, Token, TokenProcessor}
  alias Chronicle.Engine.Diagrams.Definition
  alias Chronicle.Engine.Instance.TokenState
  alias Chronicle.Engine.Nodes

  setup_all do
    case Chronicle.Engine.Scripting.ScriptPool.start_link([]) do
      {:ok, pid} -> Process.unlink(pid)
      {:error, {:already_started, _pid}} -> :ok
    end
  end

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

  test "standard loop activity uses post-test condition with max-iteration guard" do
    state =
      base_state(%{
        1 => %Nodes.Tasks.ManualTask{
          id: 1,
          outputs: [2],
          properties: %{
            "loopCharacteristics" => %{
              "condition" => "loopIteration < 5",
              "maxIterations" => 3,
              "testBefore" => false
            }
          }
        },
        2 => %Nodes.EndEvents.BlankEndEvent{id: 2}
      })

    state =
      Enum.reduce(1..7, state, fn _, acc ->
        TokenProcessor.process_active_tokens(acc)
      end)

    loop_events =
      Enum.filter(state.persistent_events, &match?(%PersistentData.LoopConditionEvaluated{}, &1))

    assert Enum.map(loop_events, & &1.iteration) == [1, 2, 3]
    assert Enum.map(loop_events, & &1.continue) == [true, true, false]
    assert List.last(loop_events).target_node == 2
    assert state.tokens[0].current_node == 2
  end

  test "compensation throw starts registered completed activity handlers once" do
    state =
      base_state(%{
        1 => %Nodes.Tasks.ManualTask{
          id: 1,
          outputs: [2],
          boundary_events: [
            %Nodes.BoundaryEvents.CompensationBoundary{id: 20, attached_to: 1, outputs: [50]}
          ]
        },
        2 => %Nodes.IntermediateThrow.CompensationEvent{id: 2, outputs: [3]},
        3 => %Nodes.EndEvents.BlankEndEvent{id: 3},
        50 => %Nodes.Tasks.ManualTask{id: 50, outputs: [51]},
        51 => %Nodes.EndEvents.BlankEndEvent{id: 51}
      })

    state =
      Enum.reduce(1..4, state, fn _, acc ->
        TokenProcessor.process_active_tokens(acc)
      end)

    assert Enum.any?(state.persistent_events, &match?(%PersistentData.CompensatableActivityCompleted{activity_node_id: 1, handler_node_id: 50}, &1))
    assert Enum.any?(state.persistent_events, &match?(%PersistentData.CompensationRequested{}, &1))
    assert Enum.any?(state.persistent_events, &match?(%PersistentData.CompensationHandlerStarted{handler_node_id: 50}, &1))
    assert map_size(state.tokens) == 2
    assert MapSet.member?(state.compensation_started, "0:1:0")
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

  test "inclusive join proceeds when no other selected token can still reach it" do
    state = inclusive_join_state(%{0 => Token.new(0, 0, 4)})

    state = TokenProcessor.process_active_tokens(state)

    assert state.tokens[0].next_node == 5
    assert MapSet.member?(state.active_tokens, 0)
    refute MapSet.member?(state.waiting_tokens, 0)
  end

  test "inclusive join waits only for selected sibling paths that can reach it" do
    state =
      inclusive_join_state(%{
        0 => Token.new(0, 0, 4),
        1 => Token.new(1, 0, 3)
      })

    first_arrival = TokenProcessor.process_active_tokens(%{state | active_tokens: MapSet.new([0])})

    assert first_arrival.tokens[0].state == :waiting_for_join
    assert MapSet.member?(first_arrival.waiting_tokens, 0)

    second_arrival =
      first_arrival
      |> Map.put(:active_tokens, MapSet.new([1]))
      |> TokenProcessor.process_active_tokens()
      |> TokenProcessor.process_active_tokens()
      |> TokenProcessor.process_active_tokens()

    assert Enum.any?(second_arrival.tokens, fn {_id, token} -> token.next_node == 5 end)
    assert Enum.any?(second_arrival.tokens, fn {_id, token} -> token.state == :joined end)
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

  defp inclusive_join_state(tokens) do
    definition = %Definition{
      name: "inclusive-join",
      version: 1,
      nodes: %{
        3 => %Nodes.Tasks.ManualTask{id: 3, outputs: [4]},
        4 => %Nodes.Gateway{id: 4, kind: :inclusive, is_merging: true, outputs: [5]},
        5 => %Nodes.EndEvents.BlankEndEvent{id: 5}
      },
      connections: %{3 => [4], 4 => [5]},
      reverse_connections: %{4 => [2, 3], 5 => [4]}
    }

    Map.merge(TokenState.base_state(), %{
      id: "inst",
      business_key: "bk",
      tenant_id: "tenant",
      definition: definition,
      tokens: tokens,
      active_tokens: tokens |> Map.keys() |> MapSet.new(),
      next_token_id: map_size(tokens)
    })
  end
end
