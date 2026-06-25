defmodule Chronicle.Engine.EvictedTimerForwardingTest do
  @moduledoc """
  Focused regression tests for evicted-timer wake ROUTING (Codex findings #3/#4).

  Two gaps the evicted path had before this fix:

    1. A boundary timer was collected WITH its boundary metadata
       (`EvictedWaitRestorer` → `WaitingHandle.Timer.boundary_node_id`) but the
       evicted cell armed / forwarded it as a plain
       `{:timer_elapsed, token_id, marker}` — while the resident replay path arms
       `{:boundary_timer_elapsed, token_id, boundary_node_id, timer_id}`
       (event_replayer.ex). So an evicted boundary timer woke the wrong
       continuation (or was ignored).

    2. The sweeper poke carried only `token_id` and `sweep_timer` resolved the
       FIRST matching handle — two timers on one token were indistinguishable.

  These tests drive the cell while RESIDENT with `instance_pid: self()`, so the
  cell's `forward_to_instance` `send`s the forwarded message straight back to the
  test process. That exercises the real arm (`register_evicted_timers`),
  fast-path `handle_info({:evicted_timer_elapsed, ...})`, sweeper
  `handle_cast({:sweep_timer, ...})`, and `forward_to_instance` clauses — no DB,
  no EventStore — and asserts the exact tuple shape the restored `Instance`
  receives.
  """
  use ExUnit.Case, async: false

  alias Chronicle.Engine.{InstanceLoadCell, WaitingHandle}
  alias Chronicle.Engine.InstanceLoadCell.Lifecycle

  @tenant "fwd-tenant"

  setup do
    # A resident cell whose "instance" is THIS test process: forwarded wakes land
    # in our mailbox as plain messages we can assert_receive on.
    iid = "fwd-#{System.unique_integer([:positive])}"
    {:ok, cell} = InstanceLoadCell.start_link({iid, @tenant, "bk-#{iid}", self()})
    %{cell: cell, iid: iid}
  end

  describe "boundary timer routing" do
    test "an evicted boundary timer fast-path arm forwards a boundary continuation, not a plain timer",
         %{cell: cell} do
      # The cell is resident pointing at us, so the forwarded wake comes straight
      # back. Arm directly via the same fast-path the evicted-from-inception
      # constructor uses, with a boundary handle whose trigger_at is in the past
      # (fires immediately).
      send(cell, {:evicted_timer_elapsed, 7, "timer:boundary:1", "boundary-node-A"})

      assert_receive {:boundary_timer_elapsed, 7, "boundary-node-A", "timer:boundary:1"}, 1_000
      refute_received {:timer_elapsed, 7, _}
    end

    test "a plain (non-boundary) evicted timer still forwards {:timer_elapsed, ...}",
         %{cell: cell} do
      send(cell, {:evicted_timer_elapsed, 3, "timer:plain:1", nil})

      assert_receive {:timer_elapsed, 3, "timer:plain:1"}, 1_000
      refute_received {:boundary_timer_elapsed, 3, _, _}
    end

    test "register_evicted_timers arms a boundary handle with its boundary_node_id",
         %{cell: cell, iid: iid} do
      handle = %WaitingHandle.Timer{
        instance_id: iid,
        tenant_id: @tenant,
        token_id: 9,
        trigger_at: System.system_time(:millisecond) - 1,
        timer_ref: "timer:boundary:9",
        boundary_node_id: "boundary-node-Z",
        is_boundary: true
      }

      # Arm on the cell process (so its send_after targets the cell). The cell is
      # resident → it forwards the elapsed wake to us.
      arm_on(cell, handle)

      assert_receive {:boundary_timer_elapsed, 9, "boundary-node-Z", "timer:boundary:9"}, 1_000
    end
  end

  describe "sweeper poke distinguishes multiple timers on one token" do
    test "two timers on one token each fire their OWN continuation", %{cell: cell, iid: iid} do
      # Two timers share token 5: one plain, one boundary. The sweeper carries the
      # durable timer_id (+ boundary_node_id) for EACH so each pokes its own
      # continuation — the old token-only poke would have collapsed them.
      plain = %WaitingHandle.Timer{
        instance_id: iid,
        tenant_id: @tenant,
        token_id: 5,
        trigger_at: System.system_time(:millisecond),
        timer_ref: "timer:plain:5",
        boundary_node_id: nil
      }

      boundary = %WaitingHandle.Timer{
        instance_id: iid,
        tenant_id: @tenant,
        token_id: 5,
        trigger_at: System.system_time(:millisecond),
        timer_ref: "timer:boundary:5",
        boundary_node_id: "boundary-node-B"
      }

      # Make the cell aware of both handles so a token-only fallback could resolve
      # them, then poke each with its explicit durable marker (what the sweeper
      # reads off the distinct registry rows).
      :sys.replace_state(cell, fn s -> %{s | waiting_handles: [plain, boundary]} end)

      InstanceLoadCell.sweep_timer(cell, 5, "timer:plain:5", nil)
      InstanceLoadCell.sweep_timer(cell, 5, "timer:boundary:5", "boundary-node-B")

      assert_receive {:timer_elapsed, 5, "timer:plain:5"}, 1_000
      assert_receive {:boundary_timer_elapsed, 5, "boundary-node-B", "timer:boundary:5"}, 1_000
    end

    test "register_evicted_waits keys two timers on one token under DISTINCT rows",
         %{iid: iid} do
      cell_pid = self()

      plain = %WaitingHandle.Timer{
        instance_id: iid,
        tenant_id: @tenant,
        token_id: 5,
        trigger_at: 111,
        timer_ref: "timer:plain:5",
        boundary_node_id: nil
      }

      boundary = %WaitingHandle.Timer{
        instance_id: iid,
        tenant_id: @tenant,
        token_id: 5,
        trigger_at: 222,
        timer_ref: "timer:boundary:5",
        boundary_node_id: "boundary-node-B"
      }

      Lifecycle.register_evicted_waits([plain, boundary], cell_pid)

      assert [{^cell_pid, {^cell_pid, 111, "timer:plain:5", nil}}] =
               Registry.lookup(:evicted_waits, {@tenant, :timer, iid, 5, "timer:plain:5"})

      assert [{^cell_pid, {^cell_pid, 222, "timer:boundary:5", "boundary-node-B"}}] =
               Registry.lookup(:evicted_waits, {@tenant, :timer, iid, 5, "timer:boundary:5"})
    end
  end

  # Arm a single timer handle's fast-path send_after FROM the cell process, so the
  # `{:evicted_timer_elapsed, ...}` message lands in the cell (which then forwards
  # to us). Runs `register_evicted_timers/2` inside the cell via :sys so `self()`
  # there is the cell.
  defp arm_on(cell, handle) do
    :sys.replace_state(cell, fn s ->
      _refs = Lifecycle.register_evicted_timers([handle], s.instance_id)
      s
    end)
  end
end
