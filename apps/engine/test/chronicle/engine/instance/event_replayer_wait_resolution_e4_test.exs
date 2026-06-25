defmodule Chronicle.Engine.Instance.EventReplayerWaitResolutionE4Test do
  @moduledoc """
  Scenario E4 for PLAIN (non-event-gateway) wait resolutions: crash AFTER a
  durable wait-resolution event but BEFORE the next event.

  When a wait resolves at runtime the live path resumes the token via
  `WaitRegistry.*` → `TokenState.resume_token/3` (token state `:continue` + a
  reconstructed continuation trigger) and re-processing dispatches to the wait
  node's `continue_after_wait/1`, which advances the POST-wait flow. The durable
  resolution event records ONLY "the wait resolved" with `current_node`/
  `target_node` = the wait node itself (instance.ex) — the actual move onto the
  post-wait output is produced by `continue_after_wait`, not by the event.

  The previous replay clauses instead set the token `:execute_current_node`,
  which on restore re-PROCESSES the wait node and re-arms/re-detects the wait:
    * SignalHandled / TimerElapsed → re-run SignalEvent/TimerEvent.process,
      re-arming a fresh `wait_for_signal` / timer (and detect_implicit_waits
      could resurrect the just-consumed signal wait);
    * ExternalTaskCompletion → re-run ExternalTask.process, arming a NEW
      external task (new UUID);
    * CallCompleted → re-run CallActivity.process, STARTING A SECOND child.

  Each test below ends the persisted log at the durable wait-resolution event
  (the next event is omitted to simulate the crash) and asserts the redesigned
  replay resumes the SELECTED post-wait continuation EXACTLY like the live path:
  token `:continue` on the wait node with the live continuation trigger, the
  resolved wait NOT re-registered, classified active (not stalled), and nothing
  duplicated.

  Pure-replay harness mirrors `event_replayer_event_gateway_e4_test.exs`
  (`EventReplayer.restore_from_events/2`, `DiagramStore`, no DB). Unique
  tenant/business_key/definition names keep it isolated from sibling files and
  the shared duplicate `:waits` Registry.
  """
  use ExUnit.Case, async: false

  alias Chronicle.Engine.{PersistentData, Nodes, Token}
  alias Chronicle.Engine.Diagrams.{Definition, DiagramStore}
  alias Chronicle.Engine.Instance.{EventReplayer, TokenState}

  @tenant "tenant-wr-e4"
  @business_key "bk-wr-e4"

  setup do
    case DiagramStore.start_link([]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
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

  defp register(definition) do
    :ok = DiagramStore.register(definition.name, definition.version, @tenant, definition)
    definition
  end

  # --- Plain SIGNAL catch -----------------------------------------------------

  test "E4 plain signal: crash after SignalHandled resumes continue, signal NOT re-awaited" do
    definition =
      register(%Definition{
        name: "wr-e4-signal",
        version: 1,
        nodes: %{
          10 => %Nodes.IntermediateCatch.SignalEvent{id: 10, signal: "go", outputs: [20]},
          20 => %Nodes.EndEvents.BlankEndEvent{id: 20}
        }
      })

    # Token armed the signal catch (SignalWaitCreated), then "go" was delivered
    # (SignalHandled with target_node = the catch node). Crash BEFORE the next
    # event, so the log ends at SignalHandled.
    events = [
      start_event(definition),
      %PersistentData.TokenFamilyCreated{token: 1, family: 0, current_node: 10},
      %PersistentData.SignalWaitCreated{token: 1, family: 0, current_node: 10, signal_name: "go"},
      %PersistentData.SignalHandled{
        token: 1,
        family: 0,
        current_node: 10,
        signal_name: "go",
        target_node: 10
      }
    ]

    assert {:ok, state} = EventReplayer.restore_from_events(events, restore_state("inst-wr-signal"))

    token = state.tokens[1]

    # Resumes via the LIVE trigger {:signal, "go"}, on the catch node, :continue.
    assert token.state == :continue
    assert token.current_node == 10
    assert token.context[:continuation_context] == {:signal, "go"}

    # The consumed signal wait is NOT re-registered (not re-awaited) — neither in
    # state nor in the shared :waits Registry — and detect_implicit_waits did NOT
    # resurrect it (the :continue guard).
    assert state.signal_waits == %{}
    assert Registry.lookup(:waits, {@tenant, :signal, "go"}) == []

    # Active, not stalled; exactly one token.
    assert MapSet.member?(state.active_tokens, 1)
    refute MapSet.member?(state.waiting_tokens, 1)
    assert map_size(state.tokens) == 1
    assert Token.active?(token)
  end

  # --- Plain TIMER catch ------------------------------------------------------

  test "E4 plain timer: crash after TimerElapsed resumes continue, timer NOT re-armed" do
    definition =
      register(%Definition{
        name: "wr-e4-timer",
        version: 1,
        nodes: %{
          10 => %Nodes.IntermediateCatch.TimerEvent{
            id: 10,
            timer_config: %{duration_ms: 60_000},
            outputs: [20]
          },
          20 => %Nodes.EndEvents.BlankEndEvent{id: 20}
        }
      })

    # Token armed the timer (TimerCreated), then it fired (TimerElapsed with
    # target_node = the catch node). Crash BEFORE the next event.
    events = [
      start_event(definition),
      %PersistentData.TokenFamilyCreated{token: 1, family: 0, current_node: 10},
      %PersistentData.TimerCreated{
        token: 1,
        family: 0,
        current_node: 10,
        timer_id: "timer-wr-1",
        trigger_at: System.system_time(:millisecond) + 60_000,
        target_node: 10
      },
      %PersistentData.TimerElapsed{
        token: 1,
        family: 0,
        current_node: 10,
        target_node: 10,
        timer_id: "timer-wr-1"
      }
    ]

    assert {:ok, state} = EventReplayer.restore_from_events(events, restore_state("inst-wr-timer"))

    token = state.tokens[1]

    # Resumes via the LIVE trigger :timer_elapsed, on the catch node, :continue —
    # NOT re-arming TimerEvent.process.
    assert token.state == :continue
    assert token.current_node == 10
    assert token.context[:continuation_context] == :timer_elapsed

    # The fired timer is NOT re-armed: no timer ref re-registered for this token
    # (reregister_timers only runs over still-OPEN timers; the elapsed timer was
    # removed from open_timers by the TimerElapsed replay).
    assert state.timer_refs == %{} or
             Enum.all?(state.timer_refs, fn {_ref, owner} -> owner != 1 end)

    assert MapSet.member?(state.active_tokens, 1)
    refute MapSet.member?(state.waiting_tokens, 1)
    assert map_size(state.tokens) == 1
  end

  # --- External task COMPLETION ----------------------------------------------

  test "E4 external task: crash after ExternalTaskCompletion resumes continue, task NOT re-armed" do
    definition =
      register(%Definition{
        name: "wr-e4-ext-task",
        version: 1,
        nodes: %{
          10 => %Nodes.ExternalTask{id: 10, kind: :service, result_variable: "out", outputs: [20]},
          20 => %Nodes.EndEvents.BlankEndEvent{id: 20}
        }
      })

    # Token armed the external task (ExternalTaskCreation), then it completed
    # (ExternalTaskCompletion, no next_node — the post-wait move is produced by
    # continue_after_wait). Crash BEFORE the next event.
    events = [
      start_event(definition),
      %PersistentData.TokenFamilyCreated{token: 1, family: 0, current_node: 10},
      %PersistentData.ExternalTaskCreation{
        token: 1,
        family: 0,
        current_node: 10,
        external_task: "task-wr-1"
      },
      %PersistentData.ExternalTaskCompletion{
        token: 1,
        family: 0,
        current_node: 10,
        external_task: "task-wr-1",
        successful: true,
        payload: %{"answer" => 42}
      }
    ]

    assert {:ok, state} =
             EventReplayer.restore_from_events(events, restore_state("inst-wr-ext"))

    token = state.tokens[1]

    # Resumes via the LIVE trigger {:complete, payload, result}, on the task node,
    # :continue — NOT re-running ExternalTask.process (which would mint a new task).
    assert token.state == :continue
    assert token.current_node == 10
    assert token.context[:continuation_context] == {:complete, %{"answer" => 42}, nil}

    # The completed task is NOT re-armed: open external tasks for this token are gone.
    assert state.external_tasks == %{}

    assert MapSet.member?(state.active_tokens, 1)
    refute MapSet.member?(state.waiting_tokens, 1)
    assert map_size(state.tokens) == 1
  end

  # --- External task CANCELLATION --------------------------------------------

  test "E4 external task cancel: crash after ExternalTaskCancellation resumes continue trigger" do
    definition =
      register(%Definition{
        name: "wr-e4-ext-cancel",
        version: 1,
        nodes: %{
          10 => %Nodes.ExternalTask{id: 10, kind: :service, outputs: [20]},
          20 => %Nodes.EndEvents.BlankEndEvent{id: 20}
        }
      })

    events = [
      start_event(definition),
      %PersistentData.TokenFamilyCreated{token: 1, family: 0, current_node: 10},
      %PersistentData.ExternalTaskCreation{
        token: 1,
        family: 0,
        current_node: 10,
        external_task: "task-wr-c1"
      },
      %PersistentData.ExternalTaskCancellation{
        token: 1,
        family: 0,
        current_node: 10,
        external_task: "task-wr-c1",
        cancellation_reason: "operator",
        continuation_node_id: 20
      }
    ]

    assert {:ok, state} =
             EventReplayer.restore_from_events(events, restore_state("inst-wr-ext-c"))

    token = state.tokens[1]

    # Resumes via the LIVE trigger {:cancel, reason, continuation_node_id} on the
    # task node — continue_after_wait then routes to NodeResult.next(20).
    assert token.state == :continue
    assert token.current_node == 10
    assert token.context[:continuation_context] == {:cancel, "operator", 20}

    assert state.external_tasks == %{}
    assert MapSet.member?(state.active_tokens, 1)
    refute MapSet.member?(state.waiting_tokens, 1)
  end

  # --- Call activity COMPLETION ----------------------------------------------

  test "E4 call completion: crash after CallCompleted resumes continue, child NOT re-started" do
    definition =
      register(%Definition{
        name: "wr-e4-call",
        version: 1,
        nodes: %{
          10 => %Nodes.CallActivity{id: 10, process_name: "child", outputs: [20]},
          20 => %Nodes.EndEvents.BlankEndEvent{id: 20}
        }
      })

    # Token started the child (CallStarted), then the child completed
    # (CallCompleted, no next_node). Crash BEFORE the next event.
    events = [
      start_event(definition),
      %PersistentData.TokenFamilyCreated{token: 1, family: 0, current_node: 10},
      %PersistentData.CallStarted{
        token: 1,
        family: 0,
        current_node: 10,
        started_process: "child-wr-1"
      },
      %PersistentData.CallCompleted{
        token: 1,
        family: 0,
        current_node: 10,
        completion_context: %{"result" => "ok"},
        successful: true
      }
    ]

    assert {:ok, state} =
             EventReplayer.restore_from_events(events, restore_state("inst-wr-call"))

    token = state.tokens[1]

    # Resumes via the LIVE trigger {:completed, completion_context, successful} on
    # the CallActivity node, :continue — NOT re-running CallActivity.process
    # (which would start a SECOND child instance).
    assert token.state == :continue
    assert token.current_node == 10
    assert token.context[:continuation_context] == {:completed, %{"result" => "ok"}, true}

    # The resolved call wait is NOT re-registered.
    assert state.call_wait_list == %{}

    assert MapSet.member?(state.active_tokens, 1)
    refute MapSet.member?(state.waiting_tokens, 1)
    assert map_size(state.tokens) == 1
  end
end
