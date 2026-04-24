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
  use ExUnit.Case, async: true

  alias Chronicle.Engine.{EvictedWaitRestorer, PersistentData, WaitingHandle}

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
  end

  describe "register_waits/1 end-to-end" do
    setup do
      case Registry.start_link(keys: :duplicate, name: :evicted_waits) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end

      :ok
    end

    test "collect → register → Registry.lookup finds the evicted message wait" do
      events = [
        start_event(id: "inst-42", business_key: "order-42", tenant: "t-x"),
        struct_like("MessageWaitCreated", %{name: "hello", token: 1})
      ]

      waits = EvictedWaitRestorer.collect_open_waits(events)
      msg_waits = Enum.filter(waits, &match?(%WaitingHandle.Message{}, &1))
      assert length(msg_waits) == 1

      Enum.each(msg_waits, fn h ->
        Registry.register(
          :evicted_waits,
          {h.tenant_id, :message, h.message_name, h.business_key},
          {h.instance_id, h}
        )
      end)

      assert [{_pid, {"inst-42", %WaitingHandle.Message{}}}] =
               Registry.lookup(:evicted_waits, {"t-x", :message, "hello", "order-42"})
    end
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
