defmodule Chronicle.Engine.PersistentEventsTest do
  use ExUnit.Case, async: true

  alias Chronicle.Engine.{EvictedWaitRestorer, PersistentData, WaitingHandle}

  test "MessageWaitCreated is a first-class persisted event for wait restoration" do
    events = [
      %PersistentData.ProcessInstanceStart{
        process_instance_id: "inst-1",
        business_key: "bk-1",
        tenant: "tenant-1",
        process_name: "p",
        process_version: 1
      },
      %PersistentData.MessageWaitCreated{
        token: 7,
        family: 0,
        current_node: 2,
        name: "approved",
        business_key: "bk-1"
      }
    ]

    assert [%WaitingHandle.Message{} = wait] =
             EvictedWaitRestorer.collect_open_waits(events)
             |> Enum.filter(&match?(%WaitingHandle.Message{}, &1))

    assert wait.instance_id == "inst-1"
    assert wait.tenant_id == "tenant-1"
    assert wait.message_name == "approved"
    assert wait.business_key == "bk-1"
    assert wait.token_id == 7
  end

  test "SignalWaitCreated is a first-class persisted event for wait restoration" do
    events = [
      %PersistentData.ProcessInstanceStart{
        process_instance_id: "inst-2",
        business_key: "bk-2",
        tenant: "tenant-2",
        process_name: "p",
        process_version: 1
      },
      %PersistentData.SignalWaitCreated{
        token: 8,
        family: 0,
        current_node: 3,
        signal_name: "refresh"
      }
    ]

    assert [%WaitingHandle.Signal{} = wait] =
             EvictedWaitRestorer.collect_open_waits(events)
             |> Enum.filter(&match?(%WaitingHandle.Signal{}, &1))

    assert wait.instance_id == "inst-2"
    assert wait.tenant_id == "tenant-2"
    assert wait.signal_name == "refresh"
    assert wait.token_id == 8
  end
end
