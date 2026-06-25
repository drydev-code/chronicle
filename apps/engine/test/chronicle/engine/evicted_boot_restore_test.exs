defmodule Chronicle.Engine.EvictedBootRestoreTest do
  @moduledoc """
  STEP 6 integration test for the evicted-only boot-restore path
  (`restore_mode: :evicted`, see `docs/evicted-restart-plan.md`).

  Proves the production boot-restore path end to end:

    * `EvictedWaitRestorer.restore_waits_for/1` (the per-instance unit that
      `restore_all/0` folds over, which `Chronicle.Supervisor` invokes when
      `restore_mode: :evicted`) restarts an active instance as an EVICTED
      `InstanceLoadCell` — NOT a resident `Instance`.
    * A restart-with-N-evicted yields ZERO resident `Instance` processes, N
      evicted cells, and an `:evicted_waits` registry populated with the cell
      pid for every wait type (message/signal value = cell_pid; timer value =
      `{cell_pid, trigger_at}`).
    * Per wait type, the corresponding trigger wakes the cell, restores the
      instance on demand (bounded by `RestoreLimiter`), and advances the token:
        - message     -> `InstanceLoadCell.deliver_message_sync` (durable)
        - signal      -> `InstanceLoadCell.deliver_signal_sync` (durable)
        - external    -> the `{:error, :evicted}` + retry contract; the retry
                         redelivers durably via `command_sync`
        - timer       -> near-future `trigger_at` fires through the cell's
                         fast-path `send_after`; PLUS a crash-durability case:
                         the cell is killed before it fires, the `TimerSweeper`
                         runs, and recovery re-drives the timer.
        - call-return -> a child completing wakes the evicted parent
                         (`{:wake, :child_completed, ...}`, exactly what
                         `Instance.notify_parent_child_completed/5` casts), which
                         restores the parent and advances past the call.
    * Crash-durability per type: killing the cell mid-restore and re-driving the
      trigger source advances EXACTLY once — the durable event log carries a
      single handled/completion event (idempotent at the restored instance).

  Harness mirrors the existing engine integration tests: registries / PubSub /
  repo come from `test_helper.exs`; this file starts the supervisors the
  evicted path needs (`LoadCellSupervisor`, `InstanceSupervisor`,
  `RestoreLimiter`, `DiagramStore`, `ScriptPool`) unlinked so restored
  Instances and cells outlive the test process. Diagram + Instance setup mirror
  `bpmn_example_workflows_test.exs` / `instance_timer_elapsed_test.exs`; the
  directly-seeded streams mirror `event_replayer_boundary_test.exs`.
  """
  use ExUnit.Case, async: false

  alias Chronicle.Engine.{
    CallReturnSweeper,
    EvictedWaitRestorer,
    Instance,
    InstanceLoadCell,
    PersistentData,
    TimerSweeper
  }

  alias Chronicle.Engine.Diagrams.{DiagramStore, Parser}
  alias Chronicle.Persistence.EventStore
  alias Chronicle.Persistence.Repo
  alias Chronicle.Persistence.Schemas.{ActiveInstance, CompletedInstance, TerminatedInstance}

  @tenant "evicted-boot"

  # ---------------------------------------------------------------------------
  # Diagrams: one single-wait flow per wait type so each instance parks on
  # exactly the wait under test, then advances to a blank end on resume.
  # ---------------------------------------------------------------------------

  @message_bpjs %{
    "name" => "evicted-boot-message",
    "version" => 1,
    "nodes" => [
      %{"id" => 1, "type" => "blankStartEvent"},
      %{
        "id" => 2,
        "type" => "intermediateCatchMessageEvent",
        "message" => %{"name" => "boot.message"}
      },
      # A trailing external task so that after the wake the instance PARKS again
      # (stays resident) instead of completing + stopping the cell. This lets us
      # assert the instance is live + resident after recovery, while the durable
      # handled event proves the consumed wait advanced.
      %{"id" => 3, "type" => "externalTask", "kind" => "service"},
      %{"id" => 4, "type" => "blankEndEvent"}
    ],
    "connections" => [
      %{"from" => 1, "to" => 2},
      %{"from" => 2, "to" => 3},
      %{"from" => 3, "to" => 4}
    ]
  }

  @signal_bpjs %{
    "name" => "evicted-boot-signal",
    "version" => 1,
    "nodes" => [
      %{"id" => 1, "type" => "blankStartEvent"},
      %{"id" => 2, "type" => "intermediateCatchSignalEvent", "signal" => "boot.signal"},
      %{"id" => 3, "type" => "externalTask", "kind" => "service"},
      %{"id" => 4, "type" => "blankEndEvent"}
    ],
    "connections" => [
      %{"from" => 1, "to" => 2},
      %{"from" => 2, "to" => 3},
      %{"from" => 3, "to" => 4}
    ]
  }

  @external_bpjs %{
    "name" => "evicted-boot-external",
    "version" => 1,
    "nodes" => [
      %{"id" => 1, "type" => "blankStartEvent"},
      %{"id" => 2, "type" => "externalTask", "kind" => "service"},
      # A second external task so the instance re-parks after the first is
      # completed via the evicted-path retry (stays resident, cell stays alive).
      %{"id" => 3, "type" => "externalTask", "kind" => "service"},
      %{"id" => 4, "type" => "blankEndEvent"}
    ],
    "connections" => [
      %{"from" => 1, "to" => 2},
      %{"from" => 2, "to" => 3},
      %{"from" => 3, "to" => 4}
    ]
  }

  @timer_bpjs %{
    "name" => "evicted-boot-timer",
    "version" => 1,
    "nodes" => [
      %{"id" => 1, "type" => "blankStartEvent"},
      %{"id" => 2, "type" => "intermediateCatchTimerEvent", "timer" => %{"durationMs" => 60_000}},
      %{"id" => 3, "type" => "externalTask", "kind" => "service"},
      %{"id" => 4, "type" => "blankEndEvent"}
    ],
    "connections" => [
      %{"from" => 1, "to" => 2},
      %{"from" => 2, "to" => 3},
      %{"from" => 3, "to" => 4}
    ]
  }

  # A flow whose token parks on a callActivity (node 2), then on a trailing
  # external task (node 3) after the child returns. We don't run a real child;
  # instead we seed the durable CallStarted directly (mirroring
  # event_replayer_boundary_test) and wake the evicted parent the way a
  # completing child would.
  @call_bpjs %{
    "name" => "evicted-boot-call",
    "version" => 1,
    "nodes" => [
      %{"id" => 1, "type" => "blankStartEvent"},
      %{"id" => 2, "type" => "callActivity", "processName" => "child-proc"},
      %{"id" => 3, "type" => "externalTask", "kind" => "service"},
      %{"id" => 4, "type" => "blankEndEvent"}
    ],
    "connections" => [
      %{"from" => 1, "to" => 2},
      %{"from" => 2, "to" => 3},
      %{"from" => 3, "to" => 4}
    ]
  }

  # An event-based gateway parking on message / signal / timer candidates. The
  # gateway emits NO per-candidate explicit wait events — its message/signal
  # candidates live only in EventGatewayActivated, so boot-restore must fold the
  # activation to surface them (the timer candidate emits its own TimerCreated).
  # The winning branch (message here) flows to an external task so the instance
  # re-parks after the wake instead of completing.
  @gateway_bpjs %{
    "name" => "evicted-boot-gateway",
    "version" => 1,
    "nodes" => [
      %{"id" => 1, "type" => "blankStartEvent"},
      %{"id" => 2, "type" => "eventBasedGateway"},
      %{
        "id" => 3,
        "type" => "intermediateCatchMessageEvent",
        "message" => %{"name" => "gw.message"}
      },
      %{"id" => 4, "type" => "intermediateCatchSignalEvent", "signal" => "gw.signal"},
      %{
        "id" => 5,
        "type" => "intermediateCatchTimerEvent",
        "timer" => %{"durationMs" => 60_000}
      },
      %{"id" => 6, "type" => "externalTask", "kind" => "service"},
      %{"id" => 7, "type" => "blankEndEvent"}
    ],
    "connections" => [
      %{"from" => 1, "to" => 2},
      %{"from" => 2, "to" => 3},
      %{"from" => 2, "to" => 4},
      %{"from" => 2, "to" => 5},
      %{"from" => 3, "to" => 6},
      %{"from" => 4, "to" => 6},
      %{"from" => 5, "to" => 6},
      %{"from" => 6, "to" => 7}
    ]
  }

  # An external task with an interrupting MESSAGE boundary (node 20) and an
  # interrupting SIGNAL boundary (node 21). The activity token parks on the
  # external task; both boundaries park message/signal waits via
  # BoundaryEventCreated WITHOUT any MessageWaitCreated/SignalWaitCreated — so
  # boot-restore must fold the boundary events to surface them, else the evicted
  # instance is unreachable on its boundary names.
  @boundary_message_bpjs %{
    "name" => "evicted-boot-boundary-message",
    "version" => 1,
    "nodes" => [
      %{"id" => 1, "type" => "blankStartEvent"},
      %{"id" => 2, "type" => "externalTask", "kind" => "service"},
      %{"id" => 3, "type" => "blankEndEvent"},
      %{
        "id" => 20,
        "type" => "messageBoundaryEvent",
        "activity" => 2,
        "message" => %{"name" => "bnd.message"}
      },
      %{"id" => 30, "type" => "blankEndEvent"}
    ],
    "connections" => [
      %{"from" => 1, "to" => 2},
      %{"from" => 2, "to" => 3},
      %{"from" => 20, "to" => 30}
    ]
  }

  @boundary_signal_bpjs %{
    "name" => "evicted-boot-boundary-signal",
    "version" => 1,
    "nodes" => [
      %{"id" => 1, "type" => "blankStartEvent"},
      %{"id" => 2, "type" => "externalTask", "kind" => "service"},
      %{"id" => 3, "type" => "blankEndEvent"},
      %{"id" => 21, "type" => "signalBoundaryEvent", "activity" => 2, "signal" => "bnd.signal"},
      %{"id" => 31, "type" => "blankEndEvent"}
    ],
    "connections" => [
      %{"from" => 1, "to" => 2},
      %{"from" => 2, "to" => 3},
      %{"from" => 21, "to" => 31}
    ]
  }

  setup_all do
    start_unlinked(Chronicle.Engine.Scripting.ScriptPool, [])
    start_unlinked(DiagramStore, [])

    start_unlinked_supervisor(
      {DynamicSupervisor,
       name: Chronicle.Engine.LoadCellSupervisor, strategy: :one_for_one}
    )

    start_unlinked_supervisor(
      {DynamicSupervisor,
       name: Chronicle.Engine.InstanceSupervisor, strategy: :one_for_one}
    )

    start_unlinked(Chronicle.Engine.RestoreLimiter, [])
    start_unlinked(TimerSweeper, [])
    start_unlinked(CallReturnSweeper, [])

    # Register every diagram so on-demand restore (EventReplayer -> DiagramStore)
    # and the restorer's keyless resolution can resolve definitions.
    for bpjs <- [
          @message_bpjs,
          @signal_bpjs,
          @external_bpjs,
          @timer_bpjs,
          @call_bpjs,
          @gateway_bpjs,
          @boundary_message_bpjs,
          @boundary_signal_bpjs
        ] do
      {:ok, definition} = Parser.parse(Jason.encode!(bpjs))
      :ok = DiagramStore.register(definition.name, definition.version, @tenant, definition)
    end

    :ok
  end

  setup do
    repo = Application.get_env(:engine, :active_repo)

    if repo do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(repo)
      # Instances and the on-demand restore Task run as separate processes;
      # share the checked-out sandbox connection with them.
      Ecto.Adapters.SQL.Sandbox.mode(repo, {:shared, self()})
      Repo.delete_all(ActiveInstance)
      Repo.delete_all(CompletedInstance)
      Repo.delete_all(TerminatedInstance)

      on_exit(fn ->
        # Cells and restored Instances are started unlinked under their dynamic
        # supervisors so they outlive the test process — but they MUST NOT leak
        # into the next test. A leaked evicted cell stays registered in
        # `:evicted_waits` under its (instance-agnostic) signal key, so a later
        # test seeding the SAME signal name would see two waiters and fail its
        # exactly-one-waiter assertion. Terminating both supervisors' children
        # here drops each cell, which (registering from its own process) also
        # clears its `:evicted_waits` rows — isolating every test.
        terminate_children(Chronicle.Engine.InstanceSupervisor)
        terminate_children(Chronicle.Engine.LoadCellSupervisor)

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

  # ===========================================================================
  # Restart-with-N-evicted: zero resident instances, N evicted cells, populated
  # :evicted_waits.
  # ===========================================================================

  describe "boot-restore lands instances as evicted cells, never resident" do
    @tag :integration
    test "N active instances restore to N evicted cells with zero resident Instances and cell-pid waits" do
      msg_id = seed_parked(@message_bpjs, &message_parked?/1)
      sig_id = seed_parked(@signal_bpjs, &signal_parked?/1)
      timer_id = seed_parked(@timer_bpjs, &timer_parked?/1)

      ids = [msg_id, sig_id, timer_id]

      # Simulate a node restart: the resident Instances are gone, only the
      # durable ActiveInstance rows remain.
      assert resident_instance_count(ids) == 0

      # Boot-restore the evicted way (the per-instance unit restore_all/0 folds).
      for id <- ids, do: assert(is_integer(EvictedWaitRestorer.restore_waits_for(id)))

      # ZERO resident Instances were materialised.
      assert resident_instance_count(ids) == 0

      # N evicted cells, each registered in :load_cells and reporting :evicted.
      for id <- ids do
        assert {:ok, cell_pid} = InstanceLoadCell.lookup(@tenant, id)
        assert InstanceLoadCell.evicted?(cell_pid)
      end

      {:ok, msg_cell} = InstanceLoadCell.lookup(@tenant, msg_id)
      {:ok, sig_cell} = InstanceLoadCell.lookup(@tenant, sig_id)
      {:ok, timer_cell} = InstanceLoadCell.lookup(@tenant, timer_id)

      # :evicted_waits is populated with the CELL PID (the canonical value the
      # gateway / consumers expect), not the old {instance_id, handle} shape.
      assert [{_o1, ^msg_cell}] =
               Registry.lookup(:evicted_waits, {@tenant, :message, "boot.message", business_key(msg_id)})

      assert [{_o2, ^sig_cell}] =
               Registry.lookup(:evicted_waits, {@tenant, :signal, "boot.signal"})

      # Timer entries carry {cell_pid, trigger_at, timer_id, boundary_node_id} so
      # the sweeper can decide due-ness — and forward the exact durable marker /
      # boundary continuation — without restoring. The key carries the timer_id so
      # two timers on one token stay distinct durable rows.
      [{timer_token, _trigger_at, timer_ref}] = open_timer_tokens(timer_id)

      assert [{_o3, {^timer_cell, trigger_at, ^timer_ref, nil}}] =
               Registry.lookup(:evicted_waits, {@tenant, :timer, timer_id, timer_token, timer_ref})

      assert is_integer(trigger_at)
    end
  end

  # ===========================================================================
  # Active-after-wake stranding (the boot-restore correctness hole): an instance
  # whose durable log ENDS at a WAKE event (MessageHandled) with an ACTIVE
  # continuation token and NO subsequent wait must be restored RESIDENT-and-
  # processed, NOT parked as a dormant evicted cell. `collect_open_waits` returns
  # NO wait for such an instance, so an evicted cell would have no
  # `:evicted_waits` row and would wait forever on a trigger that never comes.
  # ===========================================================================

  describe "active-after-wake instance restores resident and the token advances" do
    @tag :integration
    test "a log ending at MessageHandled with an active token boot-restores RESIDENT and processes it" do
      id = seed_active_after_wake()

      # Boot-restore the evicted way (the per-instance unit restore_all/0 folds).
      assert EvictedWaitRestorer.restore_waits_for(id) == :restored_resident

      # The instance is RESIDENT (the active token is being / has been processed),
      # NOT a dormant evicted cell.
      assert await_resident(id)
      assert {:error, :not_found} = InstanceLoadCell.lookup(@tenant, id)

      # The active continuation token actually ADVANCED: processing the :continue
      # token off the message catch (node 2) flows to the trailing external task
      # (node 3), which durably creates the external task. Before the fix the token
      # was stranded — no ExternalTaskCreation would ever appear.
      assert eventually(fn -> handled_count(id, PersistentData.ExternalTaskCreation) == 1 end)
      assert handled_count(id, PersistentData.ExternalTaskCreation) == 1
    end

    @tag :integration
    test "a PURELY WAITING instance still becomes an evicted cell (no regression)" do
      # Same diagram, but parked on a genuine open message wait (no wake recorded):
      # this stays passive — an evicted cell with its wait registered — proving the
      # active-token routing did not regress the scale-win path.
      id = seed_parked(@message_bpjs, &message_parked?/1)

      assert is_integer(EvictedWaitRestorer.restore_waits_for(id))

      assert {:ok, cell_pid} = InstanceLoadCell.lookup(@tenant, id)
      assert InstanceLoadCell.evicted?(cell_pid)
      assert {:error, :not_found} = Instance.lookup(@tenant, id)

      assert [{_o, ^cell_pid}] =
               Registry.lookup(:evicted_waits, {@tenant, :message, "boot.message", business_key(id)})
    end
  end

  # ===========================================================================
  # IMPLICIT message wait (CODEX finding): a token durably reached a plain
  # message catch but the engine crashed BEFORE MessageWaitCreated was persisted.
  # The resident replay reconstructs this via `EventReplayer.detect_implicit_waits`
  # as a legitimate open message wait. The OLD parallel `collect_open_waits` fold
  # surfaced NOTHING for such a stream (no MessageWaitCreated event to fold), so
  # the evicted cell had ZERO `:evicted_waits` rows and was unreachable forever.
  # The state-derived restore reads the same reconstructed state, so the implicit
  # wait IS registered and a message wake resolves it.
  # ===========================================================================

  describe "implicit message wait (catch reached, MessageWaitCreated not yet persisted)" do
    @tag :integration
    test "boot-restore registers the implicit wait and a message wake restores + advances" do
      id = seed_implicit_message_wait()

      # The OLD pure fold sees NO open wait for this stream — the precise gap.
      {:ok, streamed} = EventStore.stream(id)
      assert EvictedWaitRestorer.collect_open_waits(streamed) == []

      # The state-derived restore (live path) DOES surface the implicit wait.
      {:ok, cell_pid} = restore_evicted(id)
      assert InstanceLoadCell.evicted?(cell_pid)

      # The implicit message wait is registered against the cell pid under the
      # plain catch key — reachable by an inbound message.
      assert [{_o, ^cell_pid}] =
               Registry.lookup(
                 :evicted_waits,
                 {@tenant, :message, "boot.message", business_key(id)}
               )

      # A message wake restores the instance and consumes the implicit wait,
      # advancing the token past the catch (node 2 -> external task node 3).
      assert {:matched, _} =
               InstanceLoadCell.deliver_message_sync(cell_pid, "boot.message", %{})

      assert await_resident(id)
      refute InstanceLoadCell.evicted?(cell_pid)
      assert {:ok, _pid} = Instance.lookup(@tenant, id)
      assert eventually(fn -> handled_count(id, PersistentData.MessageHandled) == 1 end)
      assert handled_count(id, PersistentData.MessageHandled) == 1
      assert eventually(fn -> handled_count(id, PersistentData.ExternalTaskCreation) == 1 end)
    end
  end

  # ===========================================================================
  # Per-wait-type wake: restore + token advance.
  # ===========================================================================

  describe "message wait wake restores and advances the token" do
    @tag :integration
    test "deliver_message_sync on an evicted cell restores the instance and consumes the message" do
      id = seed_parked(@message_bpjs, &message_parked?/1)
      {:ok, cell_pid} = restore_evicted(id)

      assert {:matched, _} =
               InstanceLoadCell.deliver_message_sync(cell_pid, "boot.message", %{})

      # The cell is now resident and the token advanced past the catch.
      assert eventually(fn -> not InstanceLoadCell.evicted?(cell_pid) end)
      assert {:ok, _pid} = Instance.lookup(@tenant, id)

      # Consumed EXACTLY once in the durable log.
      assert handled_count(id, PersistentData.MessageHandled) == 1
    end
  end

  describe "signal wait wake restores and advances the token" do
    @tag :integration
    test "deliver_signal_sync on an evicted cell restores the instance and consumes the signal" do
      id = seed_parked(@signal_bpjs, &signal_parked?/1)
      {:ok, cell_pid} = restore_evicted(id)

      assert :ok = InstanceLoadCell.deliver_signal_sync(cell_pid, "boot.signal")

      assert eventually(fn -> not InstanceLoadCell.evicted?(cell_pid) end)
      assert {:ok, _pid} = Instance.lookup(@tenant, id)
      assert handled_count(id, PersistentData.SignalHandled) == 1
    end
  end

  describe "external-task wake honours the {:error, :evicted} + retry contract" do
    @tag :integration
    test "an evicted external task open?-checks true and a durable retry completes it once" do
      id = seed_parked(@external_bpjs, &external_parked?/1)
      task_id = open_external_task(id)
      {:ok, cell_pid} = restore_evicted(id)

      # The DeliveryReconciler safely probes an evicted task WITHOUT restoring:
      # the handle captured at boot reports the task is still open, so the lost
      # reply can be re-driven (the {:error, :evicted} side of the contract).
      assert InstanceLoadCell.external_task_open?(cell_pid, task_id)
      assert InstanceLoadCell.evicted?(cell_pid)

      # The retry redelivers durably through command_sync, restoring + advancing.
      assert :ok =
               InstanceLoadCell.command_sync(
                 cell_pid,
                 {:external_task_complete, task_id, %{"ok" => true}, %{worker: "svc"}}
               )

      assert eventually(fn -> not InstanceLoadCell.evicted?(cell_pid) end)
      assert {:ok, _pid} = Instance.lookup(@tenant, id)
      assert handled_count(id, PersistentData.ExternalTaskCompletion) == 1
    end
  end

  describe "timer wait wake restores and advances the token" do
    @tag :integration
    test "a near-past trigger_at fires through the cell's fast-path send_after" do
      # Seed parked on the timer, then rewrite the durable trigger_at to the
      # near past so the evicted cell's send_after fires almost immediately.
      id = seed_parked(@timer_bpjs, &timer_parked?/1)
      backdate_timer(id)

      {:ok, cell_pid} = restore_evicted(id)

      # The cell's fast-path Process.send_after fires {:evicted_timer_elapsed,...}
      # -> on-demand restore -> TimerElapsed appended.
      assert await_resident(id)
      refute InstanceLoadCell.evicted?(cell_pid)
      assert {:ok, _pid} = Instance.lookup(@tenant, id)
      # The token advanced exactly once: the durable TimerElapsed settles a beat
      # after the instance registers, so allow it to converge before counting.
      assert eventually(fn -> handled_count(id, PersistentData.TimerElapsed) == 1 end)
      assert handled_count(id, PersistentData.TimerElapsed) == 1
    end

    @tag :integration
    test "crash-durability: the durable row + sweeper recover a timer whose fast-path died, exactly once" do
      # Keep the trigger_at in the FUTURE so the fast-path send_after stays
      # dormant for the whole test — this isolates the durable registry row +
      # sweeper as the SOLE recovery path (the crash the safety net guards).
      id = seed_parked(@timer_bpjs, &timer_parked?/1)
      future_trigger(id)

      {:ok, cell_pid} = restore_evicted(id)
      assert InstanceLoadCell.evicted?(cell_pid)

      [{timer_token, _trigger_at, timer_ref}] = open_timer_tokens(id)

      # The durable timer row is registered with
      # {cell_pid, trigger_at, timer_id, boundary_node_id} — the safety net the
      # sweeper scans, independent of the fast-path send_after.
      assert [{_o, {^cell_pid, future_at, ^timer_ref, nil}}] =
               Registry.lookup(:evicted_waits, {@tenant, :timer, id, timer_token, timer_ref})

      assert is_integer(future_at)

      # Kill the cell, simulating the crash that kills its in-process send_after.
      # The permanent LoadCellSupervisor restarts it with the SAME evicted args,
      # re-registering the durable row (still future-dated, send_after dormant)
      # from the event log — recovery by replay.
      Process.exit(cell_pid, :kill)
      assert eventually(fn -> not Process.alive?(cell_pid) end)

      recovered_cell = wait_for_new_cell(id, cell_pid)
      assert InstanceLoadCell.evicted?(recovered_cell)

      # Drive the sweeper's exact action against the recovered cell's durable row.
      # (sweep_timer is what TimerSweeper.do_sweep pokes for a due row; we invoke
      # it directly so the fast-path send_after race is removed. The 2-arg form
      # resolves the durable marker + boundary continuation from the captured
      # handle, exactly as the full sweeper poke would.)
      InstanceLoadCell.sweep_timer(recovered_cell, timer_token)

      assert await_resident(id)
      refute InstanceLoadCell.evicted?(recovered_cell)
      assert {:ok, _pid} = Instance.lookup(@tenant, id)
      assert eventually(fn -> handled_count(id, PersistentData.TimerElapsed) == 1 end)

      # A SECOND sweep poke must be idempotent at the (now resident) instance:
      # the token already moved on, so no second TimerElapsed is appended.
      InstanceLoadCell.sweep_timer(recovered_cell, timer_token)
      Process.sleep(50)

      assert handled_count(id, PersistentData.TimerElapsed) == 1
    end

    @tag :integration
    test "TimerSweeper.sweep_now pokes a due, backdated durable timer row" do
      # An overdue (backdated) timer that has NOT yet restored: the sweeper must
      # select its durable row and poke the owning cell. We assert the selection
      # finds it (swept >= 1) and recovery lands exactly once.
      id = seed_parked(@timer_bpjs, &timer_parked?/1)
      backdate_timer(id)

      {:ok, cell_pid} = restore_evicted(id)

      # Force a sweep right away; whether the fast-path or the sweeper wins the
      # race, the durable row was due and recovery is idempotent.
      assert {:ok, swept} = TimerSweeper.sweep_now()
      assert is_integer(swept)

      assert await_resident(id)
      refute InstanceLoadCell.evicted?(cell_pid)
      assert {:ok, _pid} = Instance.lookup(@tenant, id)
      assert eventually(fn -> handled_count(id, PersistentData.TimerElapsed) == 1 end)
      assert handled_count(id, PersistentData.TimerElapsed) == 1
    end
  end

  describe "call-return wake restores the evicted parent and advances past the call" do
    @tag :integration
    test "a completing child wakes the evicted parent which restores and advances" do
      parent_id = seed_call_parent()
      {:ok, cell_pid} = restore_evicted(parent_id)
      assert InstanceLoadCell.evicted?(cell_pid)

      # Exactly what Instance.notify_parent_child_completed/5 casts to an evicted
      # parent's cell when its child completes.
      GenServer.cast(cell_pid, {:wake, :child_completed, "child-proc-inst", %{}, true})

      assert await_resident(parent_id)
      refute InstanceLoadCell.evicted?(cell_pid)
      assert {:ok, _pid} = Instance.lookup(@tenant, parent_id)

      # The call resolved exactly once.
      assert eventually(fn -> handled_count(parent_id, PersistentData.CallCompleted) == 1 end)
      assert handled_count(parent_id, PersistentData.CallCompleted) == 1
    end

    @tag :integration
    test "crash-durability: re-driving the child completion after a cell crash advances once" do
      parent_id = seed_call_parent()
      {:ok, cell_pid} = restore_evicted(parent_id)

      # Kill mid-flight; the permanent supervisor restarts the evicted parent
      # cell with the same args. Re-drive the child completion against the new
      # cell. Idempotent: a single CallCompleted survives.
      Process.exit(cell_pid, :kill)
      assert eventually(fn -> not Process.alive?(cell_pid) end)

      recovered_cell = wait_for_new_cell(parent_id, cell_pid)
      assert InstanceLoadCell.evicted?(recovered_cell)
      GenServer.cast(recovered_cell, {:wake, :child_completed, "child-proc-inst", %{}, true})

      assert await_resident(parent_id)
      refute InstanceLoadCell.evicted?(recovered_cell)
      assert {:ok, _pid} = Instance.lookup(@tenant, parent_id)
      assert eventually(fn -> handled_count(parent_id, PersistentData.CallCompleted) == 1 end)
      assert handled_count(parent_id, PersistentData.CallCompleted) == 1
    end
  end

  # ===========================================================================
  # CODEX FINDING #5: call-return to an EVICTED parent is volatile. The child
  # persists its OWN completion first, then notifies the parent by a CAST. A crash
  # between child-persist and parent-persist LOSES the parent wake with no durable
  # redrive — the parent deadlocks forever on a child that is already terminal.
  #
  # The fix registers the parent's open call wait durably as
  # `{tenant, :call, parent_id, child_id} -> {cell_pid, token_id}` and adds the
  # `CallReturnSweeper`, which re-pokes an evicted parent whose child is durably
  # terminal but whose return was never recorded. Idempotent: the parent records
  # the return EXACTLY once.
  # ===========================================================================

  describe "CallReturnSweeper durably re-drives a lost call return to an evicted parent" do
    @tag :integration
    test "open parent call wait registers a durable :call row pointing at the cell" do
      child_id = UUID.uuid4()
      parent_id = seed_call_parent(child_id)
      {:ok, cell_pid} = restore_evicted(parent_id)
      assert InstanceLoadCell.evicted?(cell_pid)

      # The durable safety-net row the sweeper scans — previously the Call handle
      # fell through `register_evicted_waits` with NO durable registration, so a
      # lost wake was unrecoverable.
      assert [{_o, {^cell_pid, _token_id}}] =
               Registry.lookup(:evicted_waits, {@tenant, :call, parent_id, child_id})
    end

    @tag :integration
    test "a terminal child with a never-delivered wake is re-driven by the sweeper, exactly once" do
      child_id = UUID.uuid4()
      parent_id = seed_call_parent(child_id)
      {:ok, cell_pid} = restore_evicted(parent_id)
      assert InstanceLoadCell.evicted?(cell_pid)

      # The child completed durably (its terminal row exists) but the volatile
      # child->parent wake was NEVER delivered: the parent is still evicted and has
      # recorded no CallCompleted. This is exactly the crash window of FINDING #5.
      seed_terminal_child(child_id)
      assert handled_count(parent_id, PersistentData.CallCompleted) == 0

      # The sweeper selects the durable :call row, sees the child is terminal while
      # the parent is still evicted, and re-pokes the cell — restoring the parent
      # and recording the return.
      assert {:ok, swept} = CallReturnSweeper.sweep_now()
      assert swept >= 1

      assert await_resident(parent_id)
      refute InstanceLoadCell.evicted?(cell_pid)
      assert {:ok, _pid} = Instance.lookup(@tenant, parent_id)
      assert eventually(fn -> handled_count(parent_id, PersistentData.CallCompleted) == 1 end)

      # A SECOND sweep must be idempotent: the parent already recorded the return,
      # so the durable :call row was unregistered on restore and no second
      # CallCompleted is appended.
      assert {:ok, 0} = CallReturnSweeper.sweep_now()
      Process.sleep(50)
      assert handled_count(parent_id, PersistentData.CallCompleted) == 1
    end

    @tag :integration
    test "child completes, parent cell killed before processing -> sweeper restores + advances exactly once" do
      # FINDING #5's exact scenario: child completes, parent evicted, the parent
      # cell is KILLED before it processes the wake. The permanent
      # LoadCellSupervisor restarts the cell (re-registering the durable :call row
      # from the event log), and the sweeper re-drives the owed return.
      child_id = UUID.uuid4()
      parent_id = seed_call_parent(child_id)
      {:ok, cell_pid} = restore_evicted(parent_id)

      # The child is durably terminal, but its volatile child->parent wake never
      # reaches the parent: the parent cell is KILLED before it processes the
      # return. (We do NOT cast a wake first — the whole point of FINDING #5 is
      # that the wake is LOST, so the cell never sees it.)
      seed_terminal_child(child_id)
      Process.exit(cell_pid, :kill)
      assert eventually(fn -> not Process.alive?(cell_pid) end)

      # The cell is restarted with the same evicted args; the durable :call row is
      # re-registered by replay. No fresh wake is delivered — only the durable
      # sweeper redrive recovers the parent.
      recovered_cell = wait_for_new_cell(parent_id, cell_pid)
      assert InstanceLoadCell.evicted?(recovered_cell)
      assert handled_count(parent_id, PersistentData.CallCompleted) == 0

      assert {:ok, swept} = CallReturnSweeper.sweep_now()
      assert swept >= 1

      assert await_resident(parent_id)
      refute InstanceLoadCell.evicted?(recovered_cell)
      assert {:ok, _pid} = Instance.lookup(@tenant, parent_id)

      # The call token advanced EXACTLY once.
      assert eventually(fn -> handled_count(parent_id, PersistentData.CallCompleted) == 1 end)
      assert handled_count(parent_id, PersistentData.CallCompleted) == 1

      # Further sweeps stay idempotent at the now-resident, recorded parent.
      assert {:ok, 0} = CallReturnSweeper.sweep_now()
      Process.sleep(50)
      assert handled_count(parent_id, PersistentData.CallCompleted) == 1
    end
  end

  # ===========================================================================
  # Event-based gateway: candidate waits register, and a wake on ANY branch
  # restores + resolves the whole gateway. (CODEX FINDING #2 regression.)
  # ===========================================================================

  describe "event-gateway boot-restore registers candidate waits and any wake resolves it" do
    @tag :integration
    test "message + signal candidate waits register in :evicted_waits and a message wake resolves" do
      id = seed_parked(@gateway_bpjs, &gateway_parked?/1)
      {:ok, cell_pid} = restore_evicted(id)
      assert InstanceLoadCell.evicted?(cell_pid)

      # Both the message AND the signal candidate of the gateway are registered
      # against the cell pid — previously the evicted restore folded ONLY explicit
      # MessageWaitCreated/SignalWaitCreated, so an event-gateway instance had NONE
      # of its candidates in :evicted_waits (unreachable until the timer fired).
      assert [{_o1, ^cell_pid}] =
               Registry.lookup(
                 :evicted_waits,
                 {@tenant, :message, "gw.message", business_key(id)}
               )

      assert [{_o2, ^cell_pid}] =
               Registry.lookup(:evicted_waits, {@tenant, :signal, "gw.signal"})

      # The timer candidate is also reachable via its durable TimerCreated.
      assert [{_timer_token, _trigger_at, _timer_ref}] = open_timer_tokens(id)

      # A wake on the MESSAGE branch restores the instance and resolves the
      # gateway (selecting the message branch, advancing to the trailing task).
      assert {:matched, _} =
               InstanceLoadCell.deliver_message_sync(cell_pid, "gw.message", %{})

      assert await_resident(id)
      refute InstanceLoadCell.evicted?(cell_pid)
      assert {:ok, _pid} = Instance.lookup(@tenant, id)
      assert eventually(fn -> handled_count(id, PersistentData.EventGatewayResolved) == 1 end)
      assert handled_count(id, PersistentData.EventGatewayResolved) == 1
    end

    @tag :integration
    test "a signal wake on the same gateway also restores and resolves" do
      id = seed_parked(@gateway_bpjs, &gateway_parked?/1)
      {:ok, cell_pid} = restore_evicted(id)
      assert InstanceLoadCell.evicted?(cell_pid)

      # The signal candidate alone is sufficient to wake + resolve the gateway,
      # proving every candidate (not just the timer) is wired.
      assert :ok = InstanceLoadCell.deliver_signal_sync(cell_pid, "gw.signal")

      assert await_resident(id)
      refute InstanceLoadCell.evicted?(cell_pid)
      assert {:ok, _pid} = Instance.lookup(@tenant, id)
      assert eventually(fn -> handled_count(id, PersistentData.EventGatewayResolved) == 1 end)
      assert handled_count(id, PersistentData.EventGatewayResolved) == 1
    end
  end

  describe "message/signal BOUNDARY boot-restore registers the wait and a wake resolves it" do
    @tag :integration
    test "an evicted instance parked on a message boundary registers + a message wake triggers it" do
      id = seed_parked(@boundary_message_bpjs, &message_boundary_parked?/1)
      {:ok, cell_pid} = restore_evicted(id)
      assert InstanceLoadCell.evicted?(cell_pid)

      # The message-boundary wait is registered against the cell pid under the
      # plain catch key — previously the restorer folded ONLY explicit
      # MessageWaitCreated, so an instance parked purely on a message BOUNDARY had
      # NO :evicted_waits row and was unreachable forever.
      assert [{_o, ^cell_pid}] =
               Registry.lookup(
                 :evicted_waits,
                 {@tenant, :message, "bnd.message", business_key(id)}
               )

      # A message wake restores the instance and fires the boundary. The durable
      # BoundaryEventTriggered is the proof the wait was reachable + resolved; the
      # interrupting boundary may complete the instance, so we gate on the durable
      # event (handled_count reads completed instances too) rather than residency.
      assert {:matched, _} =
               InstanceLoadCell.deliver_message_sync(cell_pid, "bnd.message", %{})

      assert eventually(fn -> handled_count(id, PersistentData.BoundaryEventTriggered) == 1 end)
      assert handled_count(id, PersistentData.BoundaryEventTriggered) == 1
    end

    @tag :integration
    test "an evicted instance parked on a signal boundary registers + a signal wake triggers it" do
      id = seed_parked(@boundary_signal_bpjs, &signal_boundary_parked?/1)
      {:ok, cell_pid} = restore_evicted(id)
      assert InstanceLoadCell.evicted?(cell_pid)

      assert [{_o, ^cell_pid}] =
               Registry.lookup(:evicted_waits, {@tenant, :signal, "bnd.signal"})

      assert :ok = InstanceLoadCell.deliver_signal_sync(cell_pid, "bnd.signal")

      assert eventually(fn -> handled_count(id, PersistentData.BoundaryEventTriggered) == 1 end)
      assert handled_count(id, PersistentData.BoundaryEventTriggered) == 1
    end
  end

  # ===========================================================================
  # Seeding helpers
  # ===========================================================================

  # Start a real Instance, wait until it parks on its wait, ensure its events are
  # durable, then stop it — leaving only the durable ActiveInstance row (the
  # state a node restart sees). Returns the instance id.
  defp seed_parked(bpjs, parked?) do
    {:ok, definition} = Parser.parse(Jason.encode!(bpjs))
    id = UUID.uuid4()
    bk = "bk-" <> id

    {:ok, pid} =
      Instance.start_link({definition, %{id: id, tenant_id: @tenant, business_key: bk}})

    assert eventually(fn -> parked?.(safe_state(pid)) end),
           "instance #{bpjs["name"]} did not park within deadline"

    # Events are flushed synchronously by the Instance; confirm they are durable.
    assert EventStore.current_sequence(id) > 0

    GenServer.stop(pid, :normal)
    assert eventually(fn -> Instance.lookup(@tenant, id) == {:error, :not_found} end)

    id
  end

  # Seed a parent parked on a callActivity by writing the durable stream
  # directly (mirrors event_replayer_boundary_test): ProcessInstanceStart +
  # token at the call node + CallStarted. No real child is run. `child_id`
  # defaults to the legacy string marker the wake tests use; the sweeper tests
  # pass a real UUID so a durable terminal CHILD row can also be seeded
  # (CompletedProcessInstances.process_instance_id is :binary_id).
  defp seed_call_parent(child_id \\ "child-proc-inst") do
    id = UUID.uuid4()
    bk = "bk-" <> id

    events = [
      %PersistentData.ProcessInstanceStart{
        process_instance_id: id,
        business_key: bk,
        tenant: @tenant,
        process_name: "evicted-boot-call",
        process_version: 1
      },
      %PersistentData.TokenFamilyCreated{token: 1, family: 0, current_node: 2},
      %PersistentData.CallStarted{
        token: 1,
        family: 0,
        current_node: 2,
        started_process: child_id
      }
    ]

    {:ok, _} = EventStore.append_batch(id, events)
    id
  end

  # Seed an instance whose durable log ENDS at a WAKE event (MessageHandled) with
  # an ACTIVE continuation token and NO subsequent wait — the exact crash window
  # the boot-restore hole strands: the engine recorded the wake but crashed before
  # `:process_tokens` wrote the next ExternalTaskCreation. Mirrors the live emit
  # (instance.ex message_command_events: target_node == the catch node, the token
  # replays as a :continue active token off the catch). `collect_open_waits`
  # returns NO wait for this stream. Returns the instance id.
  defp seed_active_after_wake do
    id = UUID.uuid4()
    bk = "bk-" <> id

    events = [
      %PersistentData.ProcessInstanceStart{
        process_instance_id: id,
        business_key: bk,
        tenant: @tenant,
        process_name: "evicted-boot-message",
        process_version: 1
      },
      # Token created directly on the message catch node (node 2).
      %PersistentData.TokenFamilyCreated{token: 1, family: 0, current_node: 2},
      # The WAKE: the message was durably consumed, but the following
      # :process_tokens cycle (which would advance the token to node 3 and create
      # the external task) never ran. target_node == the catch node, matching the
      # live plain-catch emit; replay sets the token :continue (active).
      %PersistentData.MessageHandled{
        token: 1,
        family: 0,
        current_node: 2,
        name: "boot.message",
        target_node: 2,
        selected_node: nil
      }
    ]

    {:ok, _} = EventStore.append_batch(id, events)

    # Sanity: this stream has NO open wait — the precise condition that strands an
    # evicted cell (nothing to register, nothing to ever wake it).
    {:ok, streamed} = EventStore.stream(id)
    assert EvictedWaitRestorer.collect_open_waits(streamed) == []

    id
  end

  # Seed an instance whose token durably reached a plain message catch (node 2 of
  # @message_bpjs) but whose MessageWaitCreated was NEVER persisted — the crash
  # window `EventReplayer.detect_implicit_waits` reconstructs as a legitimate open
  # message wait. The durable log carries only the token landing on the catch (no
  # MessageWaitCreated, no MessageHandled), so `collect_open_waits` folds NOTHING
  # while the resident replay re-opens the wait off the catch node. Returns the id.
  defp seed_implicit_message_wait do
    id = UUID.uuid4()
    bk = "bk-" <> id

    events = [
      %PersistentData.ProcessInstanceStart{
        process_instance_id: id,
        business_key: bk,
        tenant: @tenant,
        process_name: "evicted-boot-message",
        process_version: 1
      },
      # Token created directly on the message catch node (node 2). No
      # MessageWaitCreated followed: the implicit-wait crash window.
      %PersistentData.TokenFamilyCreated{token: 1, family: 0, current_node: 2}
    ]

    {:ok, _} = EventStore.append_batch(id, events)
    id
  end

  # Seed a durably-terminal child (a CompletedProcessInstances row) WITHOUT running
  # a real child. This is the durable footprint the child leaves AFTER it persists
  # its own completion — the exact state the CallReturnSweeper reads via
  # `EventStore.terminal_status/1` to decide an evicted parent's call return is owed.
  defp seed_terminal_child(child_id) do
    data =
      Jason.encode!([
        PersistentData.encode(%PersistentData.ProcessInstanceStart{
          process_instance_id: child_id,
          business_key: "bk-" <> child_id,
          tenant: @tenant,
          process_name: "child-proc",
          process_version: 1,
          parent_id: nil
        })
      ])

    %CompletedInstance{}
    |> CompletedInstance.changeset(%{process_instance_id: child_id, data: data})
    |> Repo.insert!()

    :ok
  end

  # Boot-restore a single instance as an evicted cell and return {:ok, cell_pid}.
  defp restore_evicted(id) do
    result = EvictedWaitRestorer.restore_waits_for(id)
    assert is_integer(result) or result == :already_started
    InstanceLoadCell.lookup(@tenant, id)
  end

  # Wait until an on-demand restore has fully completed: the restored `Instance`
  # is registered (resident) under {tenant, id}. `not evicted?` is NOT a safe
  # proxy for this — the cell leaves `:evicted` the instant a restore is
  # triggered (it sits in `:restore_requested`/`:restoring`), which is BEFORE the
  # restored Instance has registered. Gating on the registry lookup is the real
  # "restored + resident" post-condition the wake tests assert.
  defp await_resident(id, timeout_ms \\ 4_000) do
    eventually(fn -> match?({:ok, _pid}, Instance.lookup(@tenant, id)) end, timeout_ms)
  end

  # ===========================================================================
  # Durable-stream rewriting helpers (timer back-dating / sweeper plumbing)
  # ===========================================================================

  # Rewrite the durable TimerCreated.trigger_at (and any boundary trigger) to
  # the near past so the restored evicted cell treats the timer as due.
  defp backdate_timer(id) do
    past = System.system_time(:millisecond) - 60_000
    row = Repo.get!(ActiveInstance, id)

    data =
      row.data
      |> Jason.decode!()
      |> Enum.map(fn
        %{"type" => "TimerCreated"} = e -> Map.put(e, "trigger_at", past)
        %{"type" => "BoundaryEventCreated"} = e -> Map.put(e, "trigger_at", past)
        e -> e
      end)
      |> Jason.encode!()

    row
    |> ActiveInstance.changeset(%{data: data})
    |> Repo.update!()

    :ok
  end

  # Rewrite the durable trigger_at to the far future so the evicted cell's
  # fast-path Process.send_after stays dormant for the whole test.
  defp future_trigger(id) do
    future = System.system_time(:millisecond) + 3_600_000
    row = Repo.get!(ActiveInstance, id)

    data =
      row.data
      |> Jason.decode!()
      |> Enum.map(fn
        %{"type" => "TimerCreated"} = e -> Map.put(e, "trigger_at", future)
        %{"type" => "BoundaryEventCreated"} = e -> Map.put(e, "trigger_at", future)
        e -> e
      end)
      |> Jason.encode!()

    row
    |> ActiveInstance.changeset(%{data: data})
    |> Repo.update!()

    :ok
  end

  # After a cell crash the permanent LoadCellSupervisor restarts the cell under
  # the same {tenant, instance_id} registration with the same evicted args.
  # Wait until :load_cells resolves to a NEW pid distinct from the dead one.
  defp wait_for_new_cell(id, dead_pid) do
    eventually(fn ->
      match?({:ok, pid} when pid != dead_pid, InstanceLoadCell.lookup(@tenant, id))
    end)

    {:ok, pid} = InstanceLoadCell.lookup(@tenant, id)
    pid
  end

  # ===========================================================================
  # Inspection helpers
  # ===========================================================================

  # Terminate every child of a dynamic supervisor, isolating leaked cells /
  # instances between tests (see the `on_exit` rationale above).
  defp terminate_children(supervisor) do
    case Process.whereis(supervisor) do
      nil ->
        :ok

      _pid ->
        for {_, child, _, _} <- DynamicSupervisor.which_children(supervisor), is_pid(child) do
          DynamicSupervisor.terminate_child(supervisor, child)
        end

        :ok
    end
  rescue
    _ -> :ok
  end

  defp resident_instance_count(ids) do
    Enum.count(ids, fn id -> match?({:ok, _}, Instance.lookup(@tenant, id)) end)
  end

  defp business_key(id), do: "bk-" <> id

  # Open timer tokens (token_id + trigger_at + durable timer_ref) reconstructed
  # from the durable log. The timer_ref is part of the `:evicted_waits` key so two
  # timers on one token stay distinct durable rows.
  defp open_timer_tokens(id) do
    {:ok, events} = EventStore.stream(id)

    EvictedWaitRestorer.collect_open_waits(events)
    |> Enum.filter(&match?(%Chronicle.Engine.WaitingHandle.Timer{}, &1))
    |> Enum.map(&{&1.token_id, &1.trigger_at, &1.timer_ref})
  end

  defp open_external_task(id) do
    {:ok, events} = EventStore.stream(id)

    EvictedWaitRestorer.collect_open_waits(events)
    |> Enum.find_value(fn
      %Chronicle.Engine.WaitingHandle.ExternalTask{task_id: task_id} -> task_id
      _ -> false
    end)
  end

  defp handled_count(id, struct_module) do
    case EventStore.stream(id) do
      {:ok, events} ->
        Enum.count(events, &match?(%{__struct__: ^struct_module}, &1))

      # Once the instance completes, its events move to CompletedInstance.
      {:error, :not_found} ->
        case Repo.get(CompletedInstance, id) do
          nil ->
            0

          row ->
            row.data
            |> Jason.decode!()
            |> Enum.count(&(&1["type"] == type_name(struct_module)))
        end
    end
  end

  defp type_name(module), do: module |> Module.split() |> List.last()

  # --- parked predicates ---

  defp message_parked?(%{message_waits: w}) when map_size(w) > 0, do: true
  defp message_parked?(_), do: false

  defp signal_parked?(%{signal_waits: w}) when map_size(w) > 0, do: true
  defp signal_parked?(_), do: false

  defp external_parked?(%{external_tasks: t}) when map_size(t) > 0, do: true
  defp external_parked?(_), do: false

  defp timer_parked?(%{timer_refs: r}) when map_size(r) > 0, do: true
  defp timer_parked?(_), do: false

  # The activity token is parked once a message/signal boundary wait is registered.
  defp message_boundary_parked?(%{message_boundaries: b}) when map_size(b) > 0, do: true
  defp message_boundary_parked?(_), do: false

  defp signal_boundary_parked?(%{signal_boundaries: b}) when map_size(b) > 0, do: true
  defp signal_boundary_parked?(_), do: false

  # An event-based gateway parks the token on ALL its candidates at once: at
  # least the message + signal candidate waits are live (the timer candidate
  # also arms a send_after).
  defp gateway_parked?(%{message_waits: m, signal_waits: s})
       when map_size(m) > 0 and map_size(s) > 0,
       do: true

  defp gateway_parked?(_), do: false

  defp safe_state(pid) do
    if Process.alive?(pid), do: :sys.get_state(pid), else: %{}
  end

  # ===========================================================================
  # Generic wait + unlinked-start helpers
  # ===========================================================================

  defp eventually(fun, timeout_ms \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_eventually(fun, deadline)
  end

  defp do_eventually(fun, deadline) do
    cond do
      safe_truthy(fun) ->
        true

      System.monotonic_time(:millisecond) > deadline ->
        false

      true ->
        Process.sleep(20)
        do_eventually(fun, deadline)
    end
  end

  defp safe_truthy(fun) do
    fun.()
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp start_unlinked(module, args) do
    case module.start_link(args) do
      {:ok, pid} -> Process.unlink(pid)
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  defp start_unlinked_supervisor({DynamicSupervisor, opts}) do
    case DynamicSupervisor.start_link(opts) do
      {:ok, pid} -> Process.unlink(pid)
      {:error, {:already_started, _pid}} -> :ok
    end
  end
end
