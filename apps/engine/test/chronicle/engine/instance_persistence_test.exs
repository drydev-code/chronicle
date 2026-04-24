defmodule Chronicle.Engine.InstancePersistenceTest do
  @moduledoc """
  Finding 1: the durable ActiveInstance row must exist as soon as an
  Instance GenServer has accepted `init/1` — not only after the process
  reaches completion. Otherwise a mid-run crash loses the instance.
  """
  use ExUnit.Case, async: false

  alias Chronicle.Engine.Instance
  alias Chronicle.Persistence.EventStore
  alias Chronicle.Persistence.Repo
  alias Chronicle.Persistence.Schemas.ActiveInstance

  # A trivial BPJS with an external task, so the instance will park in a
  # waiting state after init and NOT complete. This exercises the code path
  # where the active row has to exist before completion.
  @bpjs %{
    "name" => "persistence-test-proc",
    "version" => 1,
    "nodes" => [
      %{"id" => 1, "type" => "blankStartEvent"},
      %{"id" => 2, "type" => "externalTask", "kind" => "service"},
      %{"id" => 3, "type" => "blankEndEvent"}
    ],
    "connections" => [
      %{"from" => 1, "to" => 2},
      %{"from" => 2, "to" => 3}
    ]
  }

  setup do
    repo = Application.get_env(:engine, :active_repo)

    if repo do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(repo)
      # The Instance runs as a different process; share the checked-out
      # sandbox connection with it.
      Ecto.Adapters.SQL.Sandbox.mode(repo, {:shared, self()})
      Repo.delete_all(ActiveInstance)

      on_exit(fn ->
        try do
          Ecto.Adapters.SQL.Sandbox.mode(repo, :manual)
        rescue
          _ -> :ok
        end
      end)

      {:ok, repo: repo}
    else
      {:ok, repo: nil}
    end
  end

  describe "synchronous start persistence" do
    @tag :integration
    test "creates an ActiveInstance row during init, before the process reaches a waiting state" do
      {:ok, definition} = Chronicle.Engine.Diagrams.Parser.parse(Jason.encode!(@bpjs))
      instance_id = UUID.uuid4()

      {:ok, pid} = Instance.start_link({definition, %{id: instance_id, tenant_id: "t-1"}})

      # Row must be visible *immediately* after init/1 returns successfully.
      # We don't need to wait for process_tokens to finish or for any
      # ExternalTask event to be written for the row to exist.
      row = Repo.get(ActiveInstance, instance_id)
      assert row != nil, "ActiveInstance row should exist right after start_link"

      decoded = Jason.decode!(row.data)
      assert is_list(decoded)
      assert [start_evt | _] = decoded
      assert start_evt["type"] == "ProcessInstanceStart"
      assert start_evt["process_instance_id"] == instance_id

      # Give the instance a tick to hit the external task wait; the
      # follow-up ExternalTaskCreation event should also be flushed
      # synchronously via sync_persist.
      _state = :sys.get_state(pid)

      row_after = Repo.get(ActiveInstance, instance_id)
      decoded_after = Jason.decode!(row_after.data)
      assert length(decoded_after) >= 1, "events must persist incrementally"

      # Ensure current_sequence/1 reports the same count as the row size.
      assert EventStore.current_sequence(instance_id) == length(decoded_after)

      GenServer.stop(pid, :normal)
    end

    @tag :integration
    test "last_persisted_index matches EventStore.current_sequence after init" do
      {:ok, definition} = Chronicle.Engine.Diagrams.Parser.parse(Jason.encode!(@bpjs))
      instance_id = UUID.uuid4()

      {:ok, pid} = Instance.start_link({definition, %{id: instance_id, tenant_id: "t-2"}})

      # Force all pending work to settle.
      state = :sys.get_state(pid)

      in_memory = length(state.persistent_events)
      assert state.last_persisted_index == in_memory,
             "in-memory index must equal total events after flush"

      assert EventStore.current_sequence(instance_id) == in_memory,
             "EventStore.current_sequence must match in-memory count"

      GenServer.stop(pid, :normal)
    end
  end

  describe "EventStore.current_sequence/1" do
    @tag :integration
    test "returns 0 when no active row exists" do
      assert EventStore.current_sequence(UUID.uuid4()) == 0
    end

    @tag :integration
    test "returns the number of events stored for an active instance" do
      id = UUID.uuid4()
      {:ok, _} = EventStore.create(id, %Chronicle.Engine.PersistentData.ProcessInstanceStart{
        process_instance_id: id, business_key: id, tenant: "t", process_name: "p", process_version: 1
      })
      assert EventStore.current_sequence(id) == 1

      {:ok, _} = EventStore.append(id, %Chronicle.Engine.PersistentData.TokenFamilyCreated{
        token: 1, family: 1, current_node: 2
      })
      assert EventStore.current_sequence(id) == 2
    end
  end
end
