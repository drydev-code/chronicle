defmodule Chronicle.Engine.Instance.EventReplayerBoundaryTest do
  use ExUnit.Case, async: false

  alias Chronicle.Engine.{PersistentData, Nodes}
  alias Chronicle.Engine.Diagrams.{Definition, DiagramStore}
  alias Chronicle.Engine.Instance.{EventReplayer, TokenState}

  setup do
    case DiagramStore.start_link([]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  test "BoundaryEventCancelled keeps restored boundary registries and timers closed" do
    definition = boundary_definition("boundary-cancel-restore")
    :ok = DiagramStore.register(definition.name, definition.version, "tenant-a", definition)

    events = [
      start_event(definition),
      %PersistentData.TokenFamilyCreated{token: 1, family: 0, current_node: 10},
      %PersistentData.ExternalTaskCreation{
        token: 1,
        family: 0,
        current_node: 10,
        external_task: "task-1"
      },
      %PersistentData.BoundaryEventCreated{
        token: 1,
        family: 0,
        current_node: 10,
        boundary_node_id: 20,
        boundary_type: :message,
        interrupting: true,
        name: "cancel"
      },
      %PersistentData.BoundaryEventCreated{
        token: 1,
        family: 0,
        current_node: 10,
        boundary_node_id: 21,
        boundary_type: :signal,
        interrupting: true,
        name: "sig"
      },
      %PersistentData.BoundaryEventCreated{
        token: 1,
        family: 0,
        current_node: 10,
        boundary_node_id: 22,
        boundary_type: :timer,
        interrupting: true,
        timer_id: "timer-1",
        trigger_at: System.system_time(:millisecond) + 60_000
      },
      %PersistentData.BoundaryEventCancelled{
        token: 1,
        family: 0,
        current_node: 10,
        boundary_node_id: 20,
        boundary_type: :message,
        name: "cancel"
      },
      %PersistentData.BoundaryEventCancelled{
        token: 1,
        family: 0,
        current_node: 10,
        boundary_node_id: 21,
        boundary_type: :signal,
        name: "sig"
      },
      %PersistentData.BoundaryEventCancelled{
        token: 1,
        family: 0,
        current_node: 10,
        boundary_node_id: 22,
        boundary_type: :timer,
        timer_id: "timer-1"
      }
    ]

    assert {:ok, state} = EventReplayer.restore_from_events(events, restore_state("inst-1"))

    assert state.external_tasks == %{"task-1" => 1}
    assert state.boundary_index == %{}
    assert state.message_boundaries == %{}
    assert state.signal_boundaries == %{}
    assert state.timer_refs == %{}
    assert Registry.lookup(:waits, {"tenant-a", :message, "cancel", "bk-1"}) == []
    assert Registry.lookup(:waits, {"tenant-a", :signal, "sig"}) == []
  end

  test "event-gateway timer cancellation is stable across restore" do
    definition =
      %Definition{
        name: "event-gateway-restore",
        version: 1,
        nodes: %{
          10 => %Nodes.Gateway{id: 10, kind: :event_based, outputs: [11, 12]},
          11 => %Nodes.IntermediateCatch.MessageEvent{id: 11, message: %{name: "go"}, outputs: [13]},
          12 => %Nodes.IntermediateCatch.TimerEvent{id: 12, timer_config: %{duration_ms: 60_000}, outputs: [14]},
          13 => %Nodes.EndEvents.BlankEndEvent{id: 13},
          14 => %Nodes.EndEvents.BlankEndEvent{id: 14}
        }
      }

    :ok = DiagramStore.register(definition.name, definition.version, "tenant-a", definition)

    events = [
      start_event(definition),
      %PersistentData.TokenFamilyCreated{token: 1, family: 0, current_node: 10},
      %PersistentData.TimerCreated{
        token: 1,
        family: 0,
        current_node: 10,
        timer_id: "timer-1",
        target_node: 10,
        trigger_at: System.system_time(:millisecond) + 60_000
      },
      %PersistentData.EventGatewayActivated{
        token: 1,
        family: 0,
        current_node: 10,
        message_names: ["go"],
        timer_ids: ["timer-1"]
      },
      %PersistentData.TimerCanceled{
        token: 1,
        family: 0,
        current_node: 10,
        timer_id: "timer-1",
        target_node: 13
      },
      %PersistentData.EventGatewayResolved{
        token: 1,
        family: 0,
        current_node: 10,
        trigger_type: :message,
        trigger_name: "go",
        selected_node: 11,
        target_node: 13
      }
    ]

    assert {:ok, state} = EventReplayer.restore_from_events(events, restore_state("inst-2"))

    assert state.timer_refs == %{}
    assert state.message_waits == %{}
    assert state.tokens[1].current_node == 13
    assert MapSet.member?(state.active_tokens, 1)
  end

  test "external-task error boundary trigger restores boundary path and closes siblings" do
    definition = boundary_definition("error-boundary-restore")
    :ok = DiagramStore.register(definition.name, definition.version, "tenant-a", definition)

    events = [
      start_event(definition),
      %PersistentData.TokenFamilyCreated{token: 1, family: 0, current_node: 10},
      %PersistentData.ExternalTaskCreation{
        token: 1,
        family: 0,
        current_node: 10,
        external_task: "task-1"
      },
      %PersistentData.BoundaryEventCreated{
        token: 1,
        family: 0,
        current_node: 10,
        boundary_node_id: 20,
        boundary_type: :message,
        interrupting: true,
        name: "cancel"
      },
      %PersistentData.BoundaryEventCreated{
        token: 1,
        family: 0,
        current_node: 10,
        boundary_node_id: 23,
        boundary_type: :error,
        interrupting: true
      },
      %PersistentData.ExternalTaskCompletion{
        token: 1,
        family: 0,
        current_node: 10,
        external_task: "task-1",
        successful: false,
        error: %{error_message: "boom"}
      },
      %PersistentData.BoundaryEventTriggered{
        token: 1,
        family: 0,
        current_node: 10,
        boundary_node_id: 23,
        boundary_type: :error,
        interrupting: true
      },
      %PersistentData.BoundaryEventCancelled{
        token: 1,
        family: 0,
        current_node: 10,
        boundary_node_id: 20,
        boundary_type: :message,
        name: "cancel"
      }
    ]

    assert {:ok, state} = EventReplayer.restore_from_events(events, restore_state("inst-4"))

    assert state.external_tasks == %{}
    assert state.boundary_index == %{}
    assert state.message_boundaries == %{}
    assert state.tokens[1].current_node == 23
    assert MapSet.member?(state.active_tokens, 1)
    assert Registry.lookup(:waits, {"tenant-a", :message, "cancel", "bk-1"}) == []
  end

  test "conditional wait restores as waiting until a persisted matching evaluation exists" do
    definition =
      %Definition{
        name: "conditional-restore",
        version: 1,
        nodes: %{
          10 => %Nodes.IntermediateCatch.ConditionalEvent{
            id: 10,
            condition: "ready === true",
            outputs: [11]
          },
          11 => %Nodes.EndEvents.BlankEndEvent{id: 11}
        }
      }

    :ok = DiagramStore.register(definition.name, definition.version, "tenant-a", definition)

    waiting_events = [
      start_event(definition),
      %PersistentData.TokenFamilyCreated{token: 1, family: 0, current_node: 10},
      %PersistentData.ConditionalEventEvaluated{
        token: 1,
        family: 0,
        current_node: 10,
        condition: "ready === true",
        matched: false
      },
      %PersistentData.ConditionalEventWaitCreated{
        token: 1,
        family: 0,
        current_node: 10,
        condition: "ready === true"
      }
    ]

    assert {:ok, waiting_state} =
             EventReplayer.restore_from_events(waiting_events, restore_state("inst-3"))

    assert waiting_state.tokens[1].state == :waiting_for_conditional_event
    assert MapSet.member?(waiting_state.waiting_tokens, 1)

    continued_events =
      waiting_events ++
        [
          %PersistentData.ConditionalEventEvaluated{
            token: 1,
            family: 0,
            current_node: 10,
            condition: "ready === true",
            matched: true,
            target_node: 11
          }
        ]

    assert {:ok, continued_state} =
             EventReplayer.restore_from_events(continued_events, restore_state("inst-3"))

    assert continued_state.tokens[1].current_node == 11
    assert MapSet.member?(continued_state.active_tokens, 1)
    refute MapSet.member?(continued_state.waiting_tokens, 1)
  end

  test "VariablesUpdated replays before persisted conditional evaluation continues token" do
    definition =
      %Definition{
        name: "conditional-variable-restore",
        version: 1,
        nodes: %{
          10 => %Nodes.IntermediateCatch.ConditionalEvent{
            id: 10,
            condition: "ready === true",
            outputs: [11]
          },
          11 => %Nodes.EndEvents.BlankEndEvent{id: 11}
        }
      }

    :ok = DiagramStore.register(definition.name, definition.version, "tenant-a", definition)

    events = [
      start_event(definition),
      %PersistentData.TokenFamilyCreated{token: 1, family: 0, current_node: 10},
      %PersistentData.ConditionalEventEvaluated{
        token: 1,
        family: 0,
        current_node: 10,
        condition: "ready === true",
        matched: false
      },
      %PersistentData.ConditionalEventWaitCreated{
        token: 1,
        family: 0,
        current_node: 10,
        condition: "ready === true"
      },
      %PersistentData.VariablesUpdated{
        token: 1,
        family: 0,
        current_node: 10,
        variables: %{ready: true}
      },
      %PersistentData.ConditionalEventEvaluated{
        token: 1,
        family: 0,
        current_node: 10,
        condition: "ready === true",
        matched: true,
        target_node: 11
      }
    ]

    assert {:ok, state} = EventReplayer.restore_from_events(events, restore_state("inst-5"))

    assert state.tokens[1].parameters.ready == true
    assert state.tokens[1].current_node == 11
    assert MapSet.member?(state.active_tokens, 1)
  end

  test "ExternalTaskCancellation and CallCanceled close restored waits" do
    definition =
      %Definition{
        name: "cancel-restore",
        version: 1,
        nodes: %{
          10 => %Nodes.ExternalTask{id: 10, kind: :service, outputs: [11]},
          11 => %Nodes.CallActivity{id: 11, process_name: "child", outputs: [12]},
          12 => %Nodes.EndEvents.BlankEndEvent{id: 12}
        }
      }

    :ok = DiagramStore.register(definition.name, definition.version, "tenant-a", definition)

    events = [
      start_event(definition),
      %PersistentData.TokenFamilyCreated{token: 1, family: 0, current_node: 10},
      %PersistentData.ExternalTaskCreation{
        token: 1,
        family: 0,
        current_node: 10,
        external_task: "task-1"
      },
      %PersistentData.ExternalTaskCancellation{
        token: 1,
        family: 0,
        current_node: 10,
        external_task: "task-1",
        continuation_node_id: 11
      },
      %PersistentData.CallStarted{
        token: 1,
        family: 0,
        current_node: 11,
        started_process: "child-1"
      },
      %PersistentData.CallCanceled{
        token: 1,
        family: 0,
        current_node: 11,
        next_node: 12
      }
    ]

    assert {:ok, state} = EventReplayer.restore_from_events(events, restore_state("inst-6"))

    assert state.external_tasks == %{}
    assert state.call_wait_list == %{}
    assert state.tokens[1].current_node == 12
    assert MapSet.member?(state.active_tokens, 1)
  end

  defp restore_state(instance_id) do
    Map.merge(TokenState.base_state(), %{
      id: instance_id,
      tenant_id: "tenant-a",
      instance_state: :simulating
    })
  end

  defp start_event(definition) do
    %PersistentData.ProcessInstanceStart{
      process_instance_id: "inst",
      business_key: "bk-1",
      tenant: "tenant-a",
      process_name: definition.name,
      process_version: definition.version
    }
  end

  defp boundary_definition(name) do
    %Definition{
      name: name,
      version: 1,
      nodes: %{
        10 => %Nodes.ExternalTask{
          id: 10,
          kind: :service,
          outputs: [99],
          boundary_events: []
        },
        20 => %Nodes.BoundaryEvents.MessageBoundary{id: 20, message: "cancel", outputs: [30]},
        21 => %Nodes.BoundaryEvents.SignalBoundary{id: 21, signal: "sig", outputs: [31]},
        22 => %Nodes.BoundaryEvents.TimerBoundary{id: 22, timer_config: %{duration_ms: 60_000}, outputs: [32]},
        23 => %Nodes.BoundaryEvents.ErrorBoundary{id: 23, outputs: [33]},
        30 => %Nodes.EndEvents.BlankEndEvent{id: 30},
        31 => %Nodes.EndEvents.BlankEndEvent{id: 31},
        32 => %Nodes.EndEvents.BlankEndEvent{id: 32},
        33 => %Nodes.EndEvents.BlankEndEvent{id: 33},
        99 => %Nodes.EndEvents.BlankEndEvent{id: 99}
      }
    }
  end
end
