defmodule Chronicle.Engine.EvictedWaitRestoreTest.UnknownEvent do
  @moduledoc false
  defstruct [:whatever]
end

defmodule Chronicle.Engine.EvictedWaitRestoreTest do
  @moduledoc """
  Focused unit tests for `EvictedWaitRestorer.collect_open_waits/1`.

  These tests operate on fabricated event lists and do not require a running
  engine, database, or Repo. They verify the pure reconstruction logic that
  drives wait re-registration on engine restart.
  """
  use ExUnit.Case, async: false

  alias Chronicle.Engine.{EvictedWaitRestorer, InstanceLoadCell, PersistentData, WaitingHandle}
  alias Chronicle.Engine.Diagrams.Definition
  alias Chronicle.Engine.Nodes

  defp start_event(overrides \\ []) do
    %PersistentData.ProcessInstanceStart{
      process_instance_id: Keyword.get(overrides, :id, "inst-1"),
      business_key: Keyword.get(overrides, :business_key, "bk-1"),
      tenant: Keyword.get(overrides, :tenant, "tenant-a"),
      process_name: "p",
      process_version: 1,
      start_node_id: "start"
    }
  end

  describe "collect_open_waits/1" do
    test "returns [] for an empty stream" do
      assert EvictedWaitRestorer.collect_open_waits([]) == []
    end

    test "collects an open external task" do
      events = [
        start_event(),
        %PersistentData.ExternalTaskCreation{
          token: 1,
          family: 0,
          current_node: "n1",
          external_task: "task-1",
          retry_counter: 0
        }
      ]

      assert [%WaitingHandle.ExternalTask{} = h] =
               EvictedWaitRestorer.collect_open_waits(events)

      assert h.task_id == "task-1"
      assert h.token_id == 1
      assert h.instance_id == "inst-1"
      assert h.tenant_id == "tenant-a"
    end

    test "does not collect an external task that was completed" do
      events = [
        start_event(),
        %PersistentData.ExternalTaskCreation{
          token: 1,
          family: 0,
          current_node: "n1",
          external_task: "task-1"
        },
        %PersistentData.ExternalTaskCompletion{
          token: 1,
          family: 0,
          current_node: "n1",
          external_task: "task-1",
          successful: true
        }
      ]

      assert EvictedWaitRestorer.collect_open_waits(events) == []
    end

    test "does not collect an external task that was cancelled" do
      events = [
        start_event(),
        %PersistentData.ExternalTaskCreation{
          token: 1,
          family: 0,
          current_node: "n1",
          external_task: "task-1"
        },
        %PersistentData.ExternalTaskCancellation{
          token: 1,
          family: 0,
          current_node: "n1",
          external_task: "task-1",
          cancellation_reason: "timeout"
        }
      ]

      assert EvictedWaitRestorer.collect_open_waits(events) == []
    end

    test "does not collect a retry timer that was cancelled by boundary interruption" do
      events = [
        start_event(),
        %PersistentData.TimerCreated{
          token: 1,
          family: 0,
          current_node: "task",
          timer_id: "retry:1:1",
          trigger_at: 60_000
        },
        %PersistentData.BoundaryEventTriggered{
          token: 1,
          family: 0,
          current_node: "task",
          boundary_node_id: "cancel",
          boundary_type: :message,
          interrupting: true
        },
        %PersistentData.TimerCanceled{
          token: 1,
          family: 0,
          current_node: "task",
          timer_id: "retry:1:1"
        }
      ]

      assert [] =
               EvictedWaitRestorer.collect_open_waits(events)
               |> Enum.filter(&match?(%WaitingHandle.Timer{}, &1))
    end

    test "collects open timers and drops elapsed/cancelled ones" do
      events = [
        start_event(),
        %PersistentData.TimerCreated{
          token: 1,
          family: 0,
          current_node: "n1",
          timer_id: "t-open",
          trigger_at: 1000
        },
        %PersistentData.TimerCreated{
          token: 2,
          family: 0,
          current_node: "n2",
          timer_id: "t-elapsed",
          trigger_at: 2000
        },
        %PersistentData.TimerElapsed{
          token: 2,
          family: 0,
          current_node: "n2",
          timer_id: "t-elapsed"
        },
        %PersistentData.TimerCreated{
          token: 3,
          family: 0,
          current_node: "n3",
          timer_id: "t-cancelled",
          trigger_at: 3000
        },
        %PersistentData.TimerCanceled{
          token: 3,
          family: 0,
          current_node: "n3",
          timer_id: "t-cancelled"
        }
      ]

      waits = EvictedWaitRestorer.collect_open_waits(events)
      timer_waits = Enum.filter(waits, &match?(%WaitingHandle.Timer{}, &1))

      assert length(timer_waits) == 1
      assert hd(timer_waits).token_id == 1
      assert hd(timer_waits).trigger_at == 1000
    end

    test "collects open boundary timers and drops cancelled boundary timers" do
      events = [
        start_event(),
        %PersistentData.BoundaryEventCreated{
          token: 1,
          family: 0,
          current_node: "activity",
          boundary_node_id: "b-open",
          boundary_type: :timer,
          timer_id: "bt-open",
          trigger_at: 1000
        },
        %PersistentData.BoundaryEventCreated{
          token: 1,
          family: 0,
          current_node: "activity",
          boundary_node_id: "b-cancelled",
          boundary_type: :timer,
          timer_id: "bt-cancelled",
          trigger_at: 2000
        },
        %PersistentData.BoundaryEventCancelled{
          token: 1,
          family: 0,
          current_node: "activity",
          boundary_node_id: "b-cancelled",
          boundary_type: :timer,
          timer_id: "bt-cancelled"
        }
      ]

      assert [%WaitingHandle.Timer{} = timer] =
               EvictedWaitRestorer.collect_open_waits(events)
               |> Enum.filter(&match?(%WaitingHandle.Timer{}, &1))

      assert timer.token_id == 1
      assert timer.trigger_at == 1000
      assert timer.boundary_node_id == "b-open"
      assert timer.is_boundary == true
    end

    test "collects an open message boundary and drops cancelled/triggered ones" do
      # An instance parked on a message boundary persists a BoundaryEventCreated
      # (boundary_type: :message) WITHOUT any MessageWaitCreated, so the prior
      # restorer surfaced NO handle and the evicted instance was unreachable.
      events = [
        start_event(business_key: "order-7"),
        # Open message boundary -> must surface as a Message handle.
        %PersistentData.BoundaryEventCreated{
          token: 1,
          family: 0,
          current_node: "activity",
          boundary_node_id: "mb-open",
          boundary_type: :message,
          name: "approve.boundary"
        },
        # Cancelled boundary -> dropped.
        %PersistentData.BoundaryEventCreated{
          token: 2,
          family: 0,
          current_node: "activity",
          boundary_node_id: "mb-cancelled",
          boundary_type: :message,
          name: "cancel.boundary"
        },
        %PersistentData.BoundaryEventCancelled{
          token: 2,
          family: 0,
          current_node: "activity",
          boundary_node_id: "mb-cancelled",
          boundary_type: :message,
          name: "cancel.boundary"
        },
        # Triggered boundary -> dropped.
        %PersistentData.BoundaryEventCreated{
          token: 3,
          family: 0,
          current_node: "activity",
          boundary_node_id: "mb-triggered",
          boundary_type: :message,
          name: "fired.boundary"
        },
        %PersistentData.BoundaryEventTriggered{
          token: 3,
          family: 0,
          current_node: "activity",
          boundary_node_id: "mb-triggered",
          boundary_type: :message,
          name: "fired.boundary"
        }
      ]

      assert [%WaitingHandle.Message{} = msg] =
               EvictedWaitRestorer.collect_open_waits(events)
               |> Enum.filter(&match?(%WaitingHandle.Message{}, &1))

      assert msg.message_name == "approve.boundary"
      assert msg.token_id == 1
      assert msg.business_key == "order-7"
      assert msg.is_boundary == true
      assert msg.boundary_node_id == "mb-open"
      # Without a definition a boundary defaults to keyed (never mis-routes :no_key).
      assert msg.keyless == false
    end

    test "collects an open signal boundary and drops cancelled/triggered ones" do
      events = [
        start_event(),
        %PersistentData.BoundaryEventCreated{
          token: 1,
          family: 0,
          current_node: "activity",
          boundary_node_id: "sb-open",
          boundary_type: :signal,
          name: "escalate.boundary"
        },
        %PersistentData.BoundaryEventCreated{
          token: 2,
          family: 0,
          current_node: "activity",
          boundary_node_id: "sb-cancelled",
          boundary_type: :signal,
          name: "cancel.signal"
        },
        %PersistentData.BoundaryEventCancelled{
          token: 2,
          family: 0,
          current_node: "activity",
          boundary_node_id: "sb-cancelled",
          boundary_type: :signal,
          name: "cancel.signal"
        }
      ]

      assert [%WaitingHandle.Signal{} = sig] =
               EvictedWaitRestorer.collect_open_waits(events)
               |> Enum.filter(&match?(%WaitingHandle.Signal{}, &1))

      assert sig.signal_name == "escalate.boundary"
      assert sig.token_id == 1
      assert sig.is_boundary == true
      assert sig.boundary_node_id == "sb-open"
    end

    test "a NON-INTERRUPTING message boundary stays open after triggering" do
      # A non-interrupting message boundary can fire repeatedly while the activity
      # is still waiting, so the resident EventReplayer keeps it OPEN after a
      # trigger (event_replayer.ex:545-582, `interrupting != false`). On restore
      # we must do the same: a single trigger must NOT drop the boundary wait, or
      # a LATER trigger after eviction-restart is lost. An INTERRUPTING trigger
      # still closes it; a cancellation always closes it.
      events = [
        start_event(business_key: "order-9"),
        # Non-interrupting boundary, fires once -> STILL open.
        %PersistentData.BoundaryEventCreated{
          token: 1,
          family: 0,
          current_node: "activity",
          boundary_node_id: "mb-noninterrupt",
          boundary_type: :message,
          interrupting: false,
          name: "ping.boundary"
        },
        %PersistentData.BoundaryEventTriggered{
          token: 1,
          family: 0,
          current_node: "activity",
          boundary_node_id: "mb-noninterrupt",
          boundary_type: :message,
          interrupting: false,
          name: "ping.boundary"
        },
        # Interrupting boundary, fires -> dropped.
        %PersistentData.BoundaryEventCreated{
          token: 2,
          family: 0,
          current_node: "activity",
          boundary_node_id: "mb-interrupt",
          boundary_type: :message,
          interrupting: true,
          name: "stop.boundary"
        },
        %PersistentData.BoundaryEventTriggered{
          token: 2,
          family: 0,
          current_node: "activity",
          boundary_node_id: "mb-interrupt",
          boundary_type: :message,
          interrupting: true,
          name: "stop.boundary"
        },
        # Non-interrupting boundary that was cancelled -> dropped.
        %PersistentData.BoundaryEventCreated{
          token: 3,
          family: 0,
          current_node: "activity",
          boundary_node_id: "mb-cancelled-ni",
          boundary_type: :message,
          interrupting: false,
          name: "gone.boundary"
        },
        %PersistentData.BoundaryEventCancelled{
          token: 3,
          family: 0,
          current_node: "activity",
          boundary_node_id: "mb-cancelled-ni",
          boundary_type: :message,
          name: "gone.boundary"
        }
      ]

      assert [%WaitingHandle.Message{} = msg] =
               EvictedWaitRestorer.collect_open_waits(events)
               |> Enum.filter(&match?(%WaitingHandle.Message{}, &1))

      assert msg.message_name == "ping.boundary"
      assert msg.token_id == 1
      assert msg.boundary_node_id == "mb-noninterrupt"
      assert msg.is_boundary == true
    end

    test "a NON-INTERRUPTING signal boundary stays open after triggering" do
      events = [
        start_event(),
        %PersistentData.BoundaryEventCreated{
          token: 1,
          family: 0,
          current_node: "activity",
          boundary_node_id: "sb-noninterrupt",
          boundary_type: :signal,
          interrupting: false,
          name: "tick.signal"
        },
        %PersistentData.BoundaryEventTriggered{
          token: 1,
          family: 0,
          current_node: "activity",
          boundary_node_id: "sb-noninterrupt",
          boundary_type: :signal,
          interrupting: false,
          name: "tick.signal"
        },
        # Interrupting signal boundary, fires -> dropped.
        %PersistentData.BoundaryEventCreated{
          token: 2,
          family: 0,
          current_node: "activity",
          boundary_node_id: "sb-interrupt",
          boundary_type: :signal,
          interrupting: true,
          name: "halt.signal"
        },
        %PersistentData.BoundaryEventTriggered{
          token: 2,
          family: 0,
          current_node: "activity",
          boundary_node_id: "sb-interrupt",
          boundary_type: :signal,
          interrupting: true,
          name: "halt.signal"
        }
      ]

      assert [%WaitingHandle.Signal{} = sig] =
               EvictedWaitRestorer.collect_open_waits(events)
               |> Enum.filter(&match?(%WaitingHandle.Signal{}, &1))

      assert sig.signal_name == "tick.signal"
      assert sig.token_id == 1
      assert sig.boundary_node_id == "sb-noninterrupt"
      assert sig.is_boundary == true
    end

    test "a plain MessageHandled does not drop a message boundary on the same name" do
      # Boundary waits live in a SEPARATE accumulator from plain catch waits, so a
      # stray MessageHandled (which closes a plain catch) must NOT close a boundary
      # of the same name — mirroring the resident message_boundaries/message_waits
      # split.
      events = [
        start_event(),
        %PersistentData.BoundaryEventCreated{
          token: 1,
          family: 0,
          current_node: "activity",
          boundary_node_id: "mb",
          boundary_type: :message,
          name: "shared.name"
        },
        %PersistentData.MessageHandled{token: 99, name: "shared.name"}
      ]

      assert [%WaitingHandle.Message{boundary_node_id: "mb", is_boundary: true}] =
               EvictedWaitRestorer.collect_open_waits(events)
               |> Enum.filter(&match?(%WaitingHandle.Message{}, &1))
    end

    test "collects open call waits" do
      events = [
        start_event(),
        %PersistentData.CallStarted{
          token: 1,
          family: 0,
          current_node: "n1",
          started_process: "child-1"
        }
      ]

      assert [%WaitingHandle.Call{child_id: "child-1", token_id: 1}] =
               EvictedWaitRestorer.collect_open_waits(events)
    end

    test "drops call waits that completed" do
      events = [
        start_event(),
        %PersistentData.CallStarted{
          token: 1,
          family: 0,
          current_node: "n1",
          started_process: "child-1"
        },
        %PersistentData.CallCompleted{
          token: 1,
          family: 0,
          current_node: "n1",
          successful: true
        }
      ]

      assert EvictedWaitRestorer.collect_open_waits(events) == []
    end

    test "drops call waits that were cancelled" do
      events = [
        start_event(),
        %PersistentData.CallStarted{
          token: 1,
          family: 0,
          current_node: "n1",
          started_process: "child-1"
        },
        %PersistentData.CallCanceled{
          token: 1,
          family: 0,
          current_node: "n1",
          next_node: "after-call"
        }
      ]

      assert EvictedWaitRestorer.collect_open_waits(events) == []
    end

    test "ignores unknown event types (e.g. new agent-1 events without struct)" do
      events = [
        start_event(),
        %Chronicle.Engine.EvictedWaitRestoreTest.UnknownEvent{whatever: true}
      ]

      assert EvictedWaitRestorer.collect_open_waits(events) == []
    end

    test "defaults tenant when no start event is present" do
      events = [
        %PersistentData.ExternalTaskCreation{
          token: 1,
          family: 0,
          current_node: "n1",
          external_task: "task-x"
        }
      ]

      assert [%WaitingHandle.ExternalTask{tenant_id: tid, instance_id: nil}] =
               EvictedWaitRestorer.collect_open_waits(events)

      assert tid == "00000000-0000-0000-0000-000000000000"
    end

    test "business_key on Message handle is taken from the start event" do
      events = [
        start_event(business_key: "order-42"),
        struct_like("MessageWaitCreated", %{name: "approved", token: 7})
      ]

      waits = EvictedWaitRestorer.collect_open_waits(events)
      msg = Enum.find(waits, &match?(%WaitingHandle.Message{}, &1))

      assert msg
      assert msg.message_name == "approved"
      assert msg.business_key == "order-42"
      assert msg.token_id == 7
    end

    test "message wait is keyed (keyless: false) when no definition is supplied" do
      events = [
        start_event(business_key: "order-42"),
        struct_like("MessageWaitCreated", %{name: "approved", token: 7, current_node: 10})
      ]

      msg =
        EvictedWaitRestorer.collect_open_waits(events)
        |> Enum.find(&match?(%WaitingHandle.Message{}, &1))

      assert msg.keyless == false
    end

    test "declared-keyless catch is collected with keyless: true when its definition is supplied" do
      definition =
        keyless_definition(
          keyless_node: 10,
          keyless_name: "approved",
          keyed_node: 20,
          keyed_name: "rejected"
        )

      events = [
        start_event(business_key: "order-42"),
        struct_like("MessageWaitCreated", %{name: "approved", token: 7, current_node: 10}),
        struct_like("MessageWaitCreated", %{name: "rejected", token: 8, current_node: 20})
      ]

      waits = EvictedWaitRestorer.collect_open_waits(events, definition)

      keyless = Enum.find(waits, &(match?(%WaitingHandle.Message{}, &1) and &1.message_name == "approved"))
      keyed = Enum.find(waits, &(match?(%WaitingHandle.Message{}, &1) and &1.message_name == "rejected"))

      assert keyless.keyless == true
      assert keyed.keyless == false
    end

    test "explicit MessageHandled removes a previously created message wait" do
      events = [
        start_event(),
        struct_like("MessageWaitCreated", %{name: "approved", token: 7}),
        %PersistentData.MessageHandled{
          token: 7,
          family: 0,
          current_node: "n1",
          name: "approved"
        }
      ]

      assert [] =
               EvictedWaitRestorer.collect_open_waits(events)
               |> Enum.filter(&match?(%WaitingHandle.Message{}, &1))
    end

    test "reconstructs an event gateway's message + signal + timer candidate waits" do
      # An event-based gateway emits NO per-candidate MessageWaitCreated /
      # SignalWaitCreated — only EventGatewayActivated carries the message/signal
      # candidate names. The timer candidate emits its own TimerCreated. All three
      # must surface as open waits so the evicted cell can register them.
      events = [
        start_event(business_key: "order-9"),
        %PersistentData.TimerCreated{
          token: 1,
          family: 0,
          current_node: "gw",
          timer_id: "gw-timer",
          trigger_at: 5000
        },
        %PersistentData.EventGatewayActivated{
          token: 1,
          family: 0,
          current_node: "gw",
          message_names: ["msg-a"],
          signal_names: ["sig-b"],
          timer_ids: ["gw-timer"],
          trigger_at_by_timer_id: %{"gw-timer" => 5000},
          wait_id: "wait-1"
        }
      ]

      waits = EvictedWaitRestorer.collect_open_waits(events)

      msg = Enum.find(waits, &match?(%WaitingHandle.Message{}, &1))
      sig = Enum.find(waits, &match?(%WaitingHandle.Signal{}, &1))
      timer = Enum.find(waits, &match?(%WaitingHandle.Timer{}, &1))

      assert msg.message_name == "msg-a"
      assert msg.token_id == 1
      assert msg.business_key == "order-9"

      assert sig.signal_name == "sig-b"
      assert sig.token_id == 1

      assert timer.token_id == 1
      assert timer.trigger_at == 5000
    end

    test "EventGatewayResolved closes ALL of the gateway's candidate waits" do
      # Resolving on one branch (here the message) must close the sibling signal
      # candidate too — exactly one branch wins, all siblings are cancelled.
      events = [
        start_event(),
        %PersistentData.EventGatewayActivated{
          token: 1,
          family: 0,
          current_node: "gw",
          message_names: ["msg-a"],
          signal_names: ["sig-b"],
          timer_ids: [],
          trigger_at_by_timer_id: %{},
          wait_id: "wait-1"
        },
        %PersistentData.EventGatewayResolved{
          token: 1,
          family: 0,
          current_node: "gw",
          trigger_type: :message,
          trigger_name: "msg-a",
          selected_node: "branch-msg",
          target_node: "branch-msg",
          wait_id: "wait-1"
        }
      ]

      waits = EvictedWaitRestorer.collect_open_waits(events)

      assert Enum.filter(waits, &match?(%WaitingHandle.Message{}, &1)) == []
      assert Enum.filter(waits, &match?(%WaitingHandle.Signal{}, &1)) == []
    end

    test "NEW-1: a gateway winner with no EventGatewayResolved closes ALL sibling candidates" do
      # Crash window: the durable winner (MessageHandled) is persisted, but the
      # engine died BEFORE EventGatewayResolved. The gateway has 3 candidates
      # (message + signal + timer). Reconstruction must resolve ONLY the winner
      # and leave NO stale sibling candidate wait — otherwise a sibling branch
      # could wrongly fire after boot-registration.
      events = [
        start_event(business_key: "order-9"),
        %PersistentData.TimerCreated{
          token: 1,
          family: 0,
          current_node: "gw",
          timer_id: "gw-timer",
          trigger_at: 5000
        },
        %PersistentData.EventGatewayActivated{
          token: 1,
          family: 0,
          current_node: "gw",
          message_names: ["msg-a"],
          signal_names: ["sig-b"],
          timer_ids: ["gw-timer"],
          trigger_at_by_timer_id: %{"gw-timer" => 5000},
          wait_id: "wait-1"
        },
        # The message branch wins. No EventGatewayResolved follows (crash window).
        %PersistentData.MessageHandled{
          token: 1,
          family: 0,
          current_node: "gw",
          name: "msg-a",
          selected_node: "branch-msg",
          wait_id: "wait-1"
        }
      ]

      waits = EvictedWaitRestorer.collect_open_waits(events)

      # The winner is resolved AND every sibling candidate (signal + timer) is gone.
      assert Enum.filter(waits, &match?(%WaitingHandle.Message{}, &1)) == []
      assert Enum.filter(waits, &match?(%WaitingHandle.Signal{}, &1)) == []
      assert Enum.filter(waits, &match?(%WaitingHandle.Timer{}, &1)) == []
    end

    test "NEW-1: a signal-branch gateway winner with no EventGatewayResolved closes ALL siblings" do
      # SignalHandled carries no selected_node, so the win is detected purely from
      # the parked-token set reconstructed from EventGatewayActivated.
      events = [
        start_event(business_key: "order-9"),
        %PersistentData.TimerCreated{
          token: 1,
          family: 0,
          current_node: "gw",
          timer_id: "gw-timer",
          trigger_at: 5000
        },
        %PersistentData.EventGatewayActivated{
          token: 1,
          family: 0,
          current_node: "gw",
          message_names: ["msg-a"],
          signal_names: ["sig-b"],
          timer_ids: ["gw-timer"],
          trigger_at_by_timer_id: %{"gw-timer" => 5000},
          wait_id: "wait-1"
        },
        %PersistentData.SignalHandled{
          token: 1,
          family: 0,
          current_node: "gw",
          signal_name: "sig-b"
        }
      ]

      waits = EvictedWaitRestorer.collect_open_waits(events)

      assert Enum.filter(waits, &match?(%WaitingHandle.Message{}, &1)) == []
      assert Enum.filter(waits, &match?(%WaitingHandle.Signal{}, &1)) == []
      assert Enum.filter(waits, &match?(%WaitingHandle.Timer{}, &1)) == []
    end

    test "an event gateway in a loop keeps a freshly re-opened candidate after a prior resolve" do
      # A loop re-activates the gateway after resolving the first occurrence. The
      # second activation's candidate must remain open (the resolve only closed
      # the first occurrence's token state, which is then re-opened).
      events = [
        start_event(),
        %PersistentData.EventGatewayActivated{
          token: 1,
          family: 0,
          current_node: "gw",
          message_names: ["msg-a"],
          signal_names: [],
          timer_ids: [],
          trigger_at_by_timer_id: %{},
          wait_id: "wait-1"
        },
        %PersistentData.EventGatewayResolved{
          token: 1,
          family: 0,
          current_node: "gw",
          trigger_type: :message,
          trigger_name: "msg-a",
          selected_node: "loop-back",
          target_node: "loop-back",
          wait_id: "wait-1"
        },
        %PersistentData.EventGatewayActivated{
          token: 1,
          family: 0,
          current_node: "gw",
          message_names: ["msg-a"],
          signal_names: [],
          timer_ids: [],
          trigger_at_by_timer_id: %{},
          wait_id: "wait-2"
        }
      ]

      waits = EvictedWaitRestorer.collect_open_waits(events)

      assert [%WaitingHandle.Message{message_name: "msg-a", token_id: 1}] =
               Enum.filter(waits, &match?(%WaitingHandle.Message{}, &1))
    end
  end

  describe "evicted-from-inception cell registration" do
    # Start just the pieces an evicted cell needs (registries + the load-cell
    # DynamicSupervisor) without booting the full engine (DB/RabbitMQ).
    # `setup` (not setup_all — illegal inside describe); body is idempotent.
    setup do
      ensure_registry(:evicted_waits, :duplicate)
      ensure_registry(:load_cells, :unique)

      unless Process.whereis(Chronicle.Engine.LoadCellSupervisor) do
        {:ok, _} =
          start_supervised_unlinked(
            {DynamicSupervisor,
             name: Chronicle.Engine.LoadCellSupervisor,
             strategy: :one_for_one,
             max_restarts: 1000,
             max_seconds: 5}
          )
      end

      :ok
    end

    test "starting an evicted cell registers its message wait with value = cell_pid" do
      events = [
        start_event(id: "inst-42", business_key: "order-42", tenant: "t-x"),
        struct_like("MessageWaitCreated", %{name: "hello", token: 1})
      ]

      waits = EvictedWaitRestorer.collect_open_waits(events)
      assert length(Enum.filter(waits, &match?(%WaitingHandle.Message{}, &1))) == 1

      {:ok, cell_pid} =
        DynamicSupervisor.start_child(
          Chronicle.Engine.LoadCellSupervisor,
          {InstanceLoadCell, {:evicted, "inst-42", "t-x", "order-42", waits}}
        )

      # The cell starts already evicted (no resident Instance was ever created).
      assert InstanceLoadCell.evicted?(cell_pid)

      # The wait is registered with the canonical value: the cell pid.
      assert [{_owner, ^cell_pid}] =
               Registry.lookup(:evicted_waits, {"t-x", :message, "hello", "order-42"})

      DynamicSupervisor.terminate_child(Chronicle.Engine.LoadCellSupervisor, cell_pid)
    end

    test "a boot-restored keyless catch is registered under :no_key (findable by a nil-key inbound)" do
      definition =
        keyless_definition(
          keyless_node: 10,
          keyless_name: "keyless-msg",
          keyed_node: 20,
          keyed_name: "keyed-msg"
        )

      events = [
        start_event(id: "inst-nk", business_key: "order-nk", tenant: "t-nk"),
        struct_like("MessageWaitCreated", %{name: "keyless-msg", token: 1, current_node: 10}),
        struct_like("MessageWaitCreated", %{name: "keyed-msg", token: 2, current_node: 20})
      ]

      waits = EvictedWaitRestorer.collect_open_waits(events, definition)

      {:ok, cell_pid} =
        DynamicSupervisor.start_child(
          Chronicle.Engine.LoadCellSupervisor,
          {InstanceLoadCell, {:evicted, "inst-nk", "t-nk", "order-nk", waits}}
        )

      # Keyless catch: present under BOTH the keyed business_key index and :no_key.
      assert [{_o1, ^cell_pid}] =
               Registry.lookup(:evicted_waits, {"t-nk", :message, "keyless-msg", "order-nk"})

      assert [{_o2, ^cell_pid}] =
               Registry.lookup(:evicted_waits, {"t-nk", :message, "keyless-msg", :no_key})

      # Keyed catch: keyed index only, never :no_key.
      assert [{_o3, ^cell_pid}] =
               Registry.lookup(:evicted_waits, {"t-nk", :message, "keyed-msg", "order-nk"})

      assert Registry.lookup(:evicted_waits, {"t-nk", :message, "keyed-msg", :no_key}) == []

      DynamicSupervisor.terminate_child(Chronicle.Engine.LoadCellSupervisor, cell_pid)
    end

    test "a started evicted cell is supervised under LoadCellSupervisor" do
      events = [start_event(id: "inst-99", business_key: "bk-99", tenant: "t-y")]
      waits = EvictedWaitRestorer.collect_open_waits(events)

      {:ok, cell_pid} =
        DynamicSupervisor.start_child(
          Chronicle.Engine.LoadCellSupervisor,
          {InstanceLoadCell, {:evicted, "inst-99", "t-y", "bk-99", waits}}
        )

      children = DynamicSupervisor.which_children(Chronicle.Engine.LoadCellSupervisor)
      assert Enum.any?(children, fn {_, pid, _, _} -> pid == cell_pid end)
      assert {:ok, ^cell_pid} = InstanceLoadCell.lookup("t-y", "inst-99")

      DynamicSupervisor.terminate_child(Chronicle.Engine.LoadCellSupervisor, cell_pid)
    end
  end

  describe "state-derived waits (authoritative live path) via replay_open_state + waits_from_state" do
    # These tests drive the SAME reconstruction the live boot-restore uses:
    # EventReplayer.replay_open_state/2 (the resident pure replay, incl.
    # detect_implicit_waits) -> EvictedWaitRestorer.waits_from_state/3. They need
    # a DiagramStore (replay loads the definition) but no DB/engine.
    alias Chronicle.Engine.Instance.{EventReplayer, TokenState}
    alias Chronicle.Engine.Diagrams.DiagramStore

    @sd_tenant "sd-tenant"

    setup do
      unless Process.whereis(DiagramStore) do
        {:ok, _} = start_supervised_unlinked({DiagramStore, []})
      end

      :ok
    end

    defp sd_definition do
      %Definition{
        name: "sd-proc",
        version: 1,
        nodes: %{
          # Plain message catch — a token landing here with NO MessageWaitCreated
          # is the IMPLICIT wait detect_implicit_waits reconstructs.
          "catch" => %Nodes.IntermediateCatch.MessageEvent{
            id: "catch",
            message: %{name: "implicit.msg"},
            outputs: []
          },
          # An external task host activity with a non-interrupting message boundary.
          "task" => %Nodes.ExternalTask{id: "task", outputs: []},
          "ni-b" => %Nodes.BoundaryEvents.NonInterruptingMessageBoundary{
            id: "ni-b",
            message: %{name: "ni.boundary"},
            attached_to: "task",
            outputs: []
          }
        }
      }
    end

    defp sd_start_event do
      %PersistentData.ProcessInstanceStart{
        process_instance_id: "sd-inst",
        business_key: "sd-bk",
        tenant: @sd_tenant,
        process_name: "sd-proc",
        process_version: 1,
        start_node_id: "catch"
      }
    end

    defp sd_replay_waits(events) do
      :ok = DiagramStore.register("sd-proc", 1, @sd_tenant, sd_definition())
      base = %{TokenState.base_state() | tenant_id: @sd_tenant}
      {:ok, {state, open_timers}} = EventReplayer.replay_open_state(events, base)
      EvictedWaitRestorer.waits_from_state(state, open_timers, "sd-inst")
    end

    test "IMPLICIT message wait: token on a plain catch with NO MessageWaitCreated surfaces a Message handle" do
      # The crash window: the token durably reached the message catch but the
      # engine died before MessageWaitCreated was persisted. The OLD pure fold
      # surfaces NOTHING; the state-derived path reconstructs it via the resident
      # detect_implicit_waits and surfaces the open wait.
      events = [
        sd_start_event(),
        %PersistentData.TokenFamilyCreated{token: 1, family: 0, current_node: "catch"}
      ]

      # The old parallel fold sees no wait — the precise divergence this fix ends.
      assert EvictedWaitRestorer.collect_open_waits(events) == []

      waits = sd_replay_waits(events)
      msg = Enum.find(waits, &match?(%WaitingHandle.Message{}, &1))

      assert msg
      assert msg.message_name == "implicit.msg"
      assert msg.token_id == 1
      assert msg.business_key == "sd-bk"
      assert msg.is_boundary == false
    end

    test "NON-INTERRUPTING message boundary stays open after one trigger via the state-derived path" do
      events = [
        sd_start_event(),
        %PersistentData.TokenFamilyCreated{token: 1, family: 0, current_node: "task"},
        %PersistentData.ExternalTaskCreation{
          token: 1,
          family: 0,
          current_node: "task",
          external_task: "et-1"
        },
        %PersistentData.BoundaryEventCreated{
          token: 1,
          family: 0,
          current_node: "task",
          boundary_node_id: "ni-b",
          boundary_type: :message,
          interrupting: false,
          name: "ni.boundary"
        },
        # One non-interrupting fire: the resident replay KEEPS the boundary open.
        %PersistentData.BoundaryEventTriggered{
          token: 1,
          family: 0,
          current_node: "task",
          boundary_node_id: "ni-b",
          boundary_type: :message,
          interrupting: false,
          name: "ni.boundary"
        }
      ]

      waits = sd_replay_waits(events)

      # The non-interrupting boundary is STILL an open Message handle.
      boundary_msg =
        Enum.find(waits, &(match?(%WaitingHandle.Message{}, &1) and &1.is_boundary))

      assert boundary_msg
      assert boundary_msg.message_name == "ni.boundary"
      assert boundary_msg.boundary_node_id == "ni-b"
      assert boundary_msg.token_id == 1

      # The host external-task wait also remains.
      assert Enum.any?(waits, &match?(%WaitingHandle.ExternalTask{task_id: "et-1"}, &1))
    end

    test "event-gateway candidates surface as message + signal + timer handles via the state-derived path" do
      events = [
        sd_start_event(),
        %PersistentData.TokenFamilyCreated{token: 1, family: 0, current_node: "task"},
        %PersistentData.TimerCreated{
          token: 1,
          family: 0,
          current_node: "task",
          timer_id: "gw-timer",
          trigger_at: 5000
        },
        %PersistentData.EventGatewayActivated{
          token: 1,
          family: 0,
          current_node: "task",
          message_names: ["gw.msg"],
          signal_names: ["gw.sig"],
          timer_ids: ["gw-timer"],
          trigger_at_by_timer_id: %{"gw-timer" => 5000},
          wait_id: "w1"
        }
      ]

      waits = sd_replay_waits(events)

      assert Enum.any?(waits, &match?(%WaitingHandle.Message{message_name: "gw.msg", token_id: 1}, &1))
      assert Enum.any?(waits, &match?(%WaitingHandle.Signal{signal_name: "gw.sig", token_id: 1}, &1))
      assert Enum.any?(waits, &match?(%WaitingHandle.Timer{token_id: 1, trigger_at: 5000}, &1))
    end

    test "external-task wait surfaces via the state-derived path" do
      events = [
        sd_start_event(),
        %PersistentData.TokenFamilyCreated{token: 1, family: 0, current_node: "task"},
        %PersistentData.ExternalTaskCreation{
          token: 1,
          family: 0,
          current_node: "task",
          external_task: "et-9"
        }
      ]

      waits = sd_replay_waits(events)

      assert [%WaitingHandle.ExternalTask{task_id: "et-9", token_id: 1}] =
               Enum.filter(waits, &match?(%WaitingHandle.ExternalTask{}, &1))
    end
  end

  defp ensure_registry(name, keys) do
    unless Process.whereis(name) do
      {:ok, _} = start_supervised_unlinked({Registry, keys: keys, name: name})
    end

    :ok
  end

  # Start a supervisor/registry under a detached process so it isn't linked to
  # the (short-lived) test process. Mirrors load_cell_supervision_test.exs.
  defp start_supervised_unlinked(child_spec) do
    parent = self()

    spawn(fn ->
      {mod, args} =
        case child_spec do
          {mod, args} -> {mod, args}
          %{start: {mod, :start_link, [args]}} -> {mod, args}
        end

      result = apply(mod, :start_link, [args])
      send(parent, {:started, result})
      Process.sleep(:infinity)
    end)

    receive do
      {:started, result} -> result
    after
      5_000 -> {:error, :timeout}
    end
  end

  # A minimal definition with one declared-keyless and one keyed intermediate
  # message catch, so `collect_open_waits/2` can resolve the `:no_key` opt-in.
  defp keyless_definition(opts) do
    %Definition{
      name: "evicted-keyless",
      version: 1,
      nodes: %{
        opts[:keyless_node] => %Nodes.IntermediateCatch.MessageEvent{
          id: opts[:keyless_node],
          message: %{name: opts[:keyless_name], allow_keyless: true},
          outputs: []
        },
        opts[:keyed_node] => %Nodes.IntermediateCatch.MessageEvent{
          id: opts[:keyed_node],
          message: %{name: opts[:keyed_name]},
          outputs: []
        }
      }
    }
  end

  # Build a dynamic struct mirroring future `PersistentData.MessageWaitCreated`
  # without having to depend on it at compile time.
  defp struct_like(module_name, fields) do
    mod = Module.concat([Chronicle.Engine.PersistentData, module_name])

    unless Code.ensure_loaded?(mod) do
      defmodule_dynamic(mod, Map.keys(fields))
    end

    struct(mod, fields)
  end

  defp defmodule_dynamic(mod, keys) do
    ast =
      quote do
        defmodule unquote(mod) do
          defstruct unquote(keys)
        end
      end

    Code.eval_quoted(ast)
  end
end
