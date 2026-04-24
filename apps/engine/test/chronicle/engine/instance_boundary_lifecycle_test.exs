defmodule Chronicle.Engine.InstanceBoundaryLifecycleTest do
  use ExUnit.Case, async: false

  alias Chronicle.Engine.{Instance, PersistentData}
  alias Chronicle.Persistence.Repo
  alias Chronicle.Persistence.Schemas.ActiveInstance

  setup do
    case Chronicle.Engine.Diagrams.DiagramStore.start_link([]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    repo = Application.get_env(:engine, :active_repo)

    if repo do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(repo)
      Ecto.Adapters.SQL.Sandbox.mode(repo, {:shared, self()})
      Repo.delete_all(ActiveInstance)

      on_exit(fn ->
        try do
          Ecto.Adapters.SQL.Sandbox.mode(repo, :manual)
        rescue
          _ -> :ok
        end
      end)
    end

    :ok
  end

  describe "retry wait interruption" do
    test "interrupting message boundary cancels the open retry timer durably" do
      {:ok, pid, _instance_id} = start_retry_boundary_instance("retry-message-boundary", [
        %{"id" => 20, "type" => "messageBoundaryEvent", "activity" => 2, "message" => %{"name" => "cancel"}}
      ])

      task_id = wait_for_external_task(pid)
      :ok = Instance.error_external_task_sync(pid, task_id, %{error_message: "retry"}, true, 60_000)
      retry_timer_id = wait_for_retry_timer(pid)

      :ok = Instance.send_message_sync(pid, "cancel", %{})
      state = :sys.get_state(pid)

      assert state.timer_refs == %{}
      refute Enum.any?(state.timer_ref_ids, fn {_ref, id} -> id == retry_timer_id end)

      events = state.persistent_events

      assert Enum.any?(events, &match?(%PersistentData.BoundaryEventTriggered{boundary_node_id: 20}, &1))
      assert Enum.any?(events, &match?(%PersistentData.TimerCanceled{timer_id: ^retry_timer_id}, &1))
    end

    test "interrupting signal boundary cancels the open retry timer durably" do
      {:ok, pid, _instance_id} = start_retry_boundary_instance("retry-signal-boundary", [
        %{"id" => 21, "type" => "signalBoundaryEvent", "activity" => 2, "signal" => "abort"}
      ])

      task_id = wait_for_external_task(pid)
      :ok = Instance.error_external_task_sync(pid, task_id, %{error_message: "retry"}, true, 60_000)
      retry_timer_id = wait_for_retry_timer(pid)

      :ok = Instance.send_signal_sync(pid, "abort")
      state =
        wait_until(pid, fn state ->
          Enum.any?(state.persistent_events, &match?(%PersistentData.TimerCanceled{timer_id: ^retry_timer_id}, &1))
        end)

      assert state.timer_refs == %{}

      events = state.persistent_events

      assert Enum.any?(events, &match?(%PersistentData.BoundaryEventTriggered{boundary_node_id: 21}, &1))
      assert Enum.any?(events, &match?(%PersistentData.TimerCanceled{timer_id: ^retry_timer_id}, &1))
    end

    test "interrupting timer boundary cancels the open retry timer durably" do
      {:ok, pid, _instance_id} = start_retry_boundary_instance("retry-timer-boundary", [
        %{
          "id" => 22,
          "type" => "timerBoundaryEvent",
          "activity" => 2,
          "timer" => %{"durationMs" => 60_000}
        }
      ])

      task_id = wait_for_external_task(pid)
      :ok = Instance.error_external_task_sync(pid, task_id, %{error_message: "retry"}, true, 60_000)
      retry_timer_id = wait_for_retry_timer(pid)
      {boundary_ref, boundary_timer_id} = wait_for_boundary_timer(pid, 22)

      send(pid, {:boundary_timer_elapsed, 0, 22, boundary_ref})
      state =
        wait_until(pid, fn state ->
          Enum.any?(state.persistent_events, &match?(%PersistentData.TimerCanceled{timer_id: ^retry_timer_id}, &1))
        end)

      assert state.timer_refs == %{}

      events = state.persistent_events

      assert Enum.any?(events, &match?(%PersistentData.TimerElapsed{timer_id: ^boundary_timer_id}, &1))
      assert Enum.any?(events, &match?(%PersistentData.BoundaryEventTriggered{boundary_node_id: 22}, &1))
      assert Enum.any?(events, &match?(%PersistentData.TimerCanceled{timer_id: ^retry_timer_id}, &1))
    end
  end

  describe "non-interrupting timer semantics" do
    test "non-interrupting timer boundary is one-shot and replay does not restore it" do
      {:ok, pid, instance_id} = start_retry_boundary_instance("non-interrupting-timer-boundary", [
        %{
          "id" => 23,
          "type" => "nonInterruptingTimerBoundaryEvent",
          "activity" => 2,
          "timer" => %{"durationMs" => 60_000}
        }
      ])

      _task_id = wait_for_external_task(pid)
      {boundary_ref, boundary_timer_id} = wait_for_boundary_timer(pid, 23)

      send(pid, {:boundary_timer_elapsed, 0, 23, boundary_ref})

      state =
        wait_until(pid, fn state ->
          map_size(state.timer_refs) == 0 and map_size(state.tokens) == 2
        end)

      assert Map.has_key?(state.external_tasks, state.tokens[0].context.external_task_id)
      assert state.boundary_index == %{}
      assert state.tokens[0].state == :waiting_for_external_task
      assert state.tokens[1].current_node == 123

      events = state.persistent_events
      assert Enum.any?(events, &match?(%PersistentData.BoundaryEventTriggered{timer_id: ^boundary_timer_id}, &1))

      restored_state =
        Chronicle.Engine.Instance.EventReplayer.restore_from_events(
          events,
          Map.merge(Chronicle.Engine.Instance.TokenState.base_state(), %{
            id: instance_id,
            tenant_id: "tenant-boundary",
            instance_state: :simulating
          })
        )

      assert {:ok, replayed} = restored_state
      assert replayed.timer_refs == %{}
      assert replayed.boundary_index == %{}
    end
  end

  defp start_retry_boundary_instance(name, boundary_nodes) do
    bpjs = retry_boundary_bpjs(name, boundary_nodes)
    {:ok, definition} = Chronicle.Engine.Diagrams.Parser.parse(Jason.encode!(bpjs))
    :ok = Chronicle.Engine.Diagrams.DiagramStore.register(definition.name, definition.version, "tenant-boundary", definition)
    instance_id = UUID.uuid4()
    params = %{id: instance_id, tenant_id: "tenant-boundary", business_key: "bk-#{instance_id}"}
    {:ok, pid} = Instance.start_link({definition, params})
    {:ok, pid, instance_id}
  end

  defp retry_boundary_bpjs(name, boundary_nodes) do
    boundary_ids = Enum.map(boundary_nodes, &Map.fetch!(&1, "id"))

    %{
      "name" => name,
      "version" => 1,
      "nodes" =>
        [
          %{"id" => 1, "type" => "blankStartEvent"},
          %{"id" => 2, "type" => "externalTask", "kind" => "service", "errorBehaviour" => "retry"},
          %{"id" => 3, "type" => "blankEndEvent"}
        ] ++ boundary_nodes ++ Enum.map(boundary_ids, &%{"id" => &1 + 100, "type" => "blankEndEvent"}),
      "connections" =>
        [
          %{"from" => 1, "to" => 2},
          %{"from" => 2, "to" => 3}
        ] ++ Enum.map(boundary_ids, &%{"from" => &1, "to" => &1 + 100})
    }
  end

  defp wait_for_external_task(pid) do
    state =
      wait_until(pid, fn state ->
        map_size(state.external_tasks) == 1
      end)

    state.external_tasks |> Map.keys() |> hd()
  end

  defp wait_for_retry_timer(pid) do
    state =
      wait_until(pid, fn state ->
        Enum.any?(state.timer_ref_ids, fn {_ref, id} -> is_binary(id) and String.starts_with?(id, "retry:") end)
      end)

    Enum.find_value(state.timer_ref_ids, fn {_ref, id} ->
      if is_binary(id) and String.starts_with?(id, "retry:"), do: id
    end)
  end

  defp wait_for_boundary_timer(pid, boundary_node_id) do
    state =
      wait_until(pid, fn state ->
        state.boundary_index
        |> Map.get(0, [])
        |> Enum.any?(&(&1.boundary_node_id == boundary_node_id and not is_nil(&1.timer_ref)))
      end)

    info = Enum.find(state.boundary_index[0], &(&1.boundary_node_id == boundary_node_id))
    {info.timer_ref, info.timer_id}
  end

  defp wait_until(pid, predicate, deadline \\ System.monotonic_time(:millisecond) + 2_000) do
    state = :sys.get_state(pid)

    cond do
      predicate.(state) ->
        state

      System.monotonic_time(:millisecond) > deadline ->
        flunk("condition not reached; state=#{inspect(state.instance_state)}")

      true ->
        Process.sleep(20)
        wait_until(pid, predicate, deadline)
    end
  end
end
