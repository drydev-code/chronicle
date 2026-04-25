defmodule Chronicle.Engine.BpmnExampleWorkflowsTest do
  use ExUnit.Case, async: false

  alias Chronicle.Engine.{Instance, PersistentData}
  alias Chronicle.Engine.Diagrams.{DiagramStore, Parser}
  alias Chronicle.Engine.Diagrams.SupportedFeatures
  alias Chronicle.Engine.Dmn.DmnStore
  alias Chronicle.Engine.Instance.{EventReplayer, TokenState}
  alias Chronicle.Persistence.Repo
  alias Chronicle.Persistence.Schemas.{ActiveInstance, CompletedInstance, TerminatedInstance}

  setup_all do
    case Chronicle.Engine.Scripting.ScriptPool.start_link([]) do
      {:ok, pid} -> Process.unlink(pid)
      {:error, {:already_started, _pid}} -> :ok
    end

    case DiagramStore.start_link([]) do
      {:ok, pid} -> Process.unlink(pid)
      {:error, {:already_started, _pid}} -> :ok
    end

    case DmnStore.start_link([]) do
      {:ok, pid} -> Process.unlink(pid)
      {:error, {:already_started, _pid}} -> :ok
    end

    case DynamicSupervisor.start_link(name: Chronicle.Engine.InstanceSupervisor, strategy: :one_for_one) do
      {:ok, pid} -> Process.unlink(pid)
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  setup do
    repo = Application.get_env(:engine, :active_repo)

    if repo do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(repo)
      Ecto.Adapters.SQL.Sandbox.mode(repo, {:shared, self()})
      Repo.delete_all(ActiveInstance)
      Repo.delete_all(CompletedInstance)
      Repo.delete_all(TerminatedInstance)

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

  test "example corpus uses only .bpjs files and covers every supported node type" do
    files = workflow_files()

    assert files != []
    assert Enum.all?(files, &String.ends_with?(&1, ".bpjs"))

    represented_types =
      files
      |> Enum.flat_map(fn path ->
        path
        |> File.read!()
        |> Jason.decode!()
        |> collect_node_types()
      end)
      |> MapSet.new()

    supported_types = SupportedFeatures.supported_node_types() |> MapSet.new()

    assert MapSet.difference(supported_types, represented_types) == MapSet.new()
  end

  test "all example workflow files parse successfully" do
    for path <- workflow_files() do
      assert {:ok, _definition_or_definitions} = path |> File.read!() |> Parser.parse()
    end
  end

  test "service and user task example completes through mocked workers" do
    {:ok, pid} = start_example("service-user-approval.bpjs", %{"orderId" => "A-100"})

    service_task_id = wait_for_external_task(pid, 2)
    :ok = Instance.complete_external_task_sync(pid, service_task_id, %{"total" => 42}, %{worker: "pricing"})

    user_task_id = wait_for_external_task(pid, 3)
    :ok = Instance.complete_external_task_sync(pid, user_task_id, %{"approved" => true, "limit" => 100}, %{user: "ops"})

    state = wait_for_instance_state(pid, :completed)
    event_types = event_types(state)

    assert Enum.count(state.persistent_events, &match?(%PersistentData.ExternalTaskCreation{}, &1)) == 2
    assert "ExternalTaskCompletion" in event_types
    assert completed_end_key(state) == "approved"

    assert Enum.any?(state.persistent_events, fn
             %PersistentData.ExternalTaskCreation{current_node: 2, actor_type: "service-worker"} -> true
             _ -> false
           end)

    assert Enum.any?(state.persistent_events, fn
             %PersistentData.ExternalTaskCreation{current_node: 3, actor_type: "ops-user"} -> true
             _ -> false
           end)
  end

  test "event-based gateway example consumes the customer reply branch" do
    {:ok, pid} = start_example("event-gateway-customer-reply.bpjs")

    wait_until(pid, fn state ->
      state.message_waits == %{"customer.reply" => [0]} and
        state.signal_waits == %{"customer.cancelled" => [0]}
    end)

    :ok = Instance.send_message_sync(pid, "customer.reply", %{"body" => "ready"})

    state = wait_for_instance_state(pid, :completed)

    assert Enum.any?(state.persistent_events, &match?(%PersistentData.EventGatewayActivated{}, &1))
    assert Enum.any?(state.persistent_events, &match?(%PersistentData.MessageHandled{name: "customer.reply"}, &1))

    assert Enum.any?(state.persistent_events, fn
             %PersistentData.EventGatewayResolved{trigger_type: :message, selected_node: 3, target_node: 5} -> true
             _ -> false
           end)

    assert completed_end_key(state) == "reply_done"
  end

  test "loop and compensation example records durable loop decisions and handler start" do
    {:ok, pid} = start_example("loop-compensation.bpjs")

    state =
      wait_until(pid, fn state ->
        Enum.any?(state.persistent_events, &match?(%PersistentData.CompensationHandlerStarted{}, &1))
      end)

    loop_events =
      Enum.filter(state.persistent_events, &match?(%PersistentData.LoopConditionEvaluated{}, &1))

    assert Enum.map(loop_events, & &1.iteration) == [1, 2]
    assert Enum.map(loop_events, & &1.continue) == [true, false]
    assert Enum.any?(state.persistent_events, &match?(%PersistentData.CompensationRequested{}, &1))
    assert Enum.any?(state.persistent_events, &match?(%PersistentData.CompensationHandlerStarted{handler_node_id: 21}, &1))

    final_state = wait_for_instance_state(pid, :completed)
    assert Enum.any?(final_state.persistent_events, &match?(%PersistentData.NoOpTaskCompleted{current_node: 21}, &1))
  end

  test "conditional boundary example is driven by a mocked variable update" do
    {:ok, pid} = start_example("conditional-boundary-escalation.bpjs")

    _task_id = wait_for_external_task(pid, 2)
    :ok = Instance.update_variables_sync(pid, %{"blocked" => true})

    state = wait_for_instance_state(pid, :completed)

    assert Enum.any?(state.persistent_events, fn
             %PersistentData.VariablesUpdated{variables: %{"blocked" => true}} -> true
             _ -> false
           end)

    assert Enum.any?(state.persistent_events, fn
             %PersistentData.BoundaryEventTriggered{boundary_node_id: 30, boundary_type: :conditional} -> true
             _ -> false
           end)

    assert state.external_tasks == %{}
    assert completed_end_key(state) == "escalated"

    {:ok, restored} =
      EventReplayer.restore_from_events(
        state.persistent_events,
        Map.merge(TokenState.base_state(), %{
          id: state.id,
          tenant_id: state.tenant_id,
          instance_state: :simulating
        })
      )

    assert restored.external_tasks == %{}
  end

  test "script, rules, send, throw, signal, and message-end example completes" do
    :ok = DmnStore.register("example-risk-rules", nil, "tenant-examples", risk_rules_dmn())

    {:ok, pid} = start_example("script-rules-and-throws.bpjs")
    state = wait_for_instance_state(pid, :completed)

    assert Enum.any?(state.persistent_events, &match?(%PersistentData.MessageThrown{name: "audit.sent"}, &1))
    assert Enum.any?(state.persistent_events, &match?(%PersistentData.MessageThrown{name: "audit.thrown"}, &1))
    assert Enum.any?(state.persistent_events, &match?(%PersistentData.SignalThrown{signal_name: "audit.signal"}, &1))
    assert completed_end_key(state) == "message_end"
  end

  test "parallel and inclusive gateway example joins selected paths" do
    {:ok, pid} = start_example("parallel-inclusive-gateways.bpjs", %{"takeA" => true, "takeB" => true})
    state = wait_for_instance_state(pid, :completed)

    assert Enum.count(state.persistent_events, &match?(%PersistentData.TokenFamilyCreated{}, &1)) >= 4
    assert completed_end_key(state) == "done"
  end

  test "intermediate catch and link example is driven through timer, message, signal, and conditional waits" do
    {:ok, pid} = start_example("intermediate-catches-and-link.bpjs", %{"ready" => true})

    state = wait_until(pid, &(map_size(&1.timer_refs) == 1))
    [{timer_ref, token_id}] = Enum.to_list(state.timer_refs)
    timer_id = Map.fetch!(state.timer_ref_ids, timer_ref)
    Process.cancel_timer(timer_ref)
    send(pid, {:timer_elapsed, token_id, timer_id})

    wait_until(pid, &(&1.message_waits == %{"catch.message" => [0]}))
    :ok = Instance.send_message_sync(pid, "catch.message", %{})

    wait_until(pid, &(&1.signal_waits == %{"catch.signal" => [0]}))
    :ok = Instance.send_signal_sync(pid, "catch.signal")

    state = wait_for_instance_state(pid, :completed)

    assert Enum.any?(state.persistent_events, &match?(%PersistentData.TimerElapsed{}, &1))
    assert Enum.any?(state.persistent_events, &match?(%PersistentData.MessageHandled{name: "catch.message"}, &1))
    assert Enum.any?(state.persistent_events, &match?(%PersistentData.SignalHandled{signal_name: "catch.signal"}, &1))
    assert Enum.any?(state.persistent_events, &match?(%PersistentData.ConditionalEventEvaluated{matched: true}, &1))
    assert Enum.any?(state.persistent_events, &match?(%PersistentData.LinkTraversed{link_name: "skip_to_here"}, &1))
    assert completed_end_key(state) == "done"
  end

  test "start events example can begin from each supported start node" do
    start_nodes = [{1, "blank_done"}, {10, "message_done"}, {20, "signal_done"}, {30, "timer_done"}, {40, "conditional_done"}]

    for {start_node_id, end_key} <- start_nodes do
      {:ok, pid} = start_example("start-events.bpjs", %{"startNow" => true}, start_node_id: start_node_id)
      state = wait_for_instance_state(pid, :completed)
      assert completed_end_key(state) == end_key
    end
  end

  test "conditional start example is executed through the conditional-start command path" do
    {:ok, definition} = load_definition("start-events.bpjs")
    :ok = DiagramStore.register(definition.name, definition.version, "tenant-examples", definition)

    assert [] =
             Chronicle.Engine.ConditionalStarts.evaluate("tenant-examples", %{"startNow" => false},
               process_name: "example-start-events"
             )

    assert [{:ok, result}] =
             Chronicle.Engine.ConditionalStarts.evaluate("tenant-examples", %{"startNow" => true},
               process_name: "example-start-events",
               business_key: "bk-conditional-example"
             )

    assert result.start_node_id == 40

    {:ok, pid} = Instance.lookup("tenant-examples", result.process_instance_id)
    state = wait_for_instance_state(pid, :completed)
    assert completed_end_key(state) == "conditional_done"
  end

  test "call activity example starts and completes a registered child workflow" do
    {:ok, child} = load_definition("call-activity-child.bpjs")
    :ok = DiagramStore.register(child.name, child.version, "tenant-examples", child)

    {:ok, pid} = start_example("call-activity-parent.bpjs")
    state = wait_for_instance_state(pid, :completed)

    assert Enum.any?(state.persistent_events, &match?(%PersistentData.CallStarted{}, &1))
    assert Enum.any?(state.persistent_events, &match?(%PersistentData.CallCompleted{successful: true}, &1))
    assert completed_end_key(state) == "done"
  end

  defp start_example(file_name, start_parameters \\ %{}, opts \\ []) do
    {:ok, definition} = load_definition(file_name)

    :ok = DiagramStore.register(definition.name, definition.version, "tenant-examples", definition)

    params = %{
      id: UUID.uuid4(),
      tenant_id: "tenant-examples",
      business_key: "bk-#{System.unique_integer([:positive])}",
      start_parameters: start_parameters,
      start_node_id: Keyword.get(opts, :start_node_id)
    }

    Instance.start_link({definition, params})
  end

  defp load_definition(file_name) do
    file_name
    |> example_path()
    |> File.read!()
    |> Parser.parse()
  end

  defp example_path(file_name) do
    Path.expand("../../../../../examples/workflows/#{file_name}", __DIR__)
  end

  defp workflow_files do
    Path.expand("../../../../../examples/workflows/*.bpjs", __DIR__)
    |> Path.wildcard()
  end

  defp collect_node_types(%{"nodes" => nodes}) when is_list(nodes) do
    Enum.map(nodes, &Map.fetch!(&1, "type"))
  end

  defp collect_node_types(%{"processes" => processes}) when is_list(processes) do
    Enum.flat_map(processes, &collect_node_types/1)
  end

  defp wait_for_external_task(pid, node_id) do
    state =
      wait_until(pid, fn state ->
        Enum.any?(state.external_tasks, fn {_task_id, token_id} ->
          token = Map.fetch!(state.tokens, token_id)
          token.current_node == node_id and token.state == :waiting_for_external_task
        end)
      end)

    Enum.find_value(state.external_tasks, fn {task_id, token_id} ->
      token = Map.fetch!(state.tokens, token_id)
      if token.current_node == node_id, do: task_id
    end)
  end

  defp wait_for_instance_state(pid, instance_state) do
    wait_until(pid, &(&1.instance_state == instance_state))
  end

  defp wait_until(pid, predicate, deadline \\ System.monotonic_time(:millisecond) + 2_000) do
    state = :sys.get_state(pid)

    cond do
      predicate.(state) ->
        state

      System.monotonic_time(:millisecond) > deadline ->
        flunk("condition not reached; state=#{inspect(state.instance_state)} events=#{inspect(event_types(state))}")

      true ->
        Process.sleep(20)
        wait_until(pid, predicate, deadline)
    end
  end

  defp event_types(state) do
    Enum.map(state.persistent_events, &(&1.__struct__ |> Module.split() |> List.last()))
  end

  defp completed_end_key(state) do
    state
    |> Map.fetch!(:completed_tokens)
    |> Enum.map(&Map.fetch!(state.tokens, &1))
    |> Enum.map(& &1.context[:completion_data])
    |> Enum.find_value(&Map.get(&1, :end_event_key))
  end

  defp risk_rules_dmn do
    """
    <definitions xmlns="https://www.omg.org/spec/DMN/20191111/MODEL/">
      <decision id="risk" name="Risk">
        <decisionTable hitPolicy="FIRST">
          <input id="amountInput" label="amount">
            <inputExpression id="amountExpression" typeRef="number">
              <text>amount</text>
            </inputExpression>
          </input>
          <output id="riskOutput" name="risk" typeRef="string" />
          <rule id="high">
            <inputEntry><text>&gt;= 50</text></inputEntry>
            <outputEntry><text>"high"</text></outputEntry>
          </rule>
          <rule id="low">
            <inputEntry><text>-</text></inputEntry>
            <outputEntry><text>"low"</text></outputEntry>
          </rule>
        </decisionTable>
      </decision>
    </definitions>
    """
  end
end
